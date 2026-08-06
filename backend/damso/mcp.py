"""Read-only local stdio MCP server for canonical Meeting Hub records.

Search runs against the rebuildable SQLite index (``index.sqlite3``) derived
from the file store, while full meeting and profile payloads are still read
from the canonical files. The three tool names and their existing response
fields are stable; new fields are only ever added, never renamed or removed.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Mapping

from .index import build_index, index_path, nfc, open_index
from .people import read_profile


# Below this, the trigram tokenizer produces zero tokens for the query term
# (each token is 3 characters), so an FTS5 MATCH against it always returns
# zero rows regardless of what the index contains. search()/search_people()
# fall back to a plain substring LIKE scan under this length instead.
TRIGRAM_MINIMUM_LENGTH = 3


class SearchBackendUnavailable(RuntimeError):
    """Raised when a keyword search is requested but the FTS5 trigram index could not be built."""


TOOL_DEFINITIONS = [
    {
        "name": "search_meetings",
        "description": "Search local meetings by date, speaker or keyword. This tool never writes data.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {"type": "string"},
                "speaker": {"type": "string"},
                "keyword": {"type": "string"},
            },
        },
    },
    {
        "name": "get_meeting",
        "description": "Get metadata, stored summary and transcript for one local meeting.",
        "inputSchema": {"type": "object", "properties": {"stem": {"type": "string"}}, "required": ["stem"]},
    },
    {
        "name": "get_speaker",
        "description": "Get one local speaker profile and that person's meeting history.",
        "inputSchema": {"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]},
    },
    {
        "name": "search_people",
        "description": "Search local people by name or profile notes. This tool never writes data.",
        "inputSchema": {"type": "object", "properties": {"keyword": {"type": "string"}}, "required": ["keyword"]},
    },
]


def fts5_available(connection: Any) -> bool:
    row = connection.execute("SELECT value FROM meta WHERE key = 'fts5_available'").fetchone()
    return row is not None and row["value"] == "1"


def fts5_phrase(term: str) -> str:
    """Quote a raw keyword as an FTS5 phrase so it can't be parsed as query syntax (AND/OR/NEAR/-/*)."""
    return '"' + term.replace('"', '""') + '"'


def plain_snippet(text: str, limit: int = 120) -> str:
    trimmed = text.strip()
    if len(trimmed) <= limit:
        return trimmed
    return trimmed[:limit].rstrip() + " …"


class ReadOnlyStore:
    def __init__(self, root: Path):
        self.root = root.expanduser().resolve()
        self.recordings = self.root / "Plaud" / "recordings"
        self.peoples = self.root / "Plaud" / "peoples"

    def connection(self):
        return open_index(self.root)

    def search(self, date: str | None = None, speaker: str | None = None, keyword: str | None = None) -> list[dict[str, Any]]:
        if keyword:
            return self._search_by_keyword(date, speaker, keyword)
        return self._search_without_keyword(date, speaker)

    def _search_without_keyword(self, date: str | None, speaker: str | None) -> list[dict[str, Any]]:
        query = ["SELECT m.* FROM meetings m"]
        clauses: list[str] = []
        parameters: list[Any] = []
        if speaker:
            query.append(
                "JOIN participants p ON p.stem = m.stem AND lower(p.person) LIKE ?"
            )
            parameters.append(f"%{speaker.lower()}%")
        if date:
            clauses.append("m.created_at LIKE ?")
            parameters.append(f"{date}%")
        if clauses:
            query.append("WHERE " + " AND ".join(clauses))
        query.append("ORDER BY m.created_at DESC")
        connection = self.connection()
        try:
            rows = connection.execute(" ".join(query), parameters).fetchall()
        finally:
            connection.close()
        return [public_metadata_from_row(row, self.read_record(row["stem"]) or {}) for row in rows]

    def _search_by_keyword(self, date: str | None, speaker: str | None, keyword: str) -> list[dict[str, Any]]:
        normalized = nfc(keyword).strip().lower()
        if not normalized:
            return self._search_without_keyword(date, speaker)
        connection = self.connection()
        try:
            if not fts5_available(connection):
                raise SearchBackendUnavailable(
                    "FTS5/trigram search index is unavailable on this sqlite3 build; keyword search cannot run"
                )
            if len(normalized) < TRIGRAM_MINIMUM_LENGTH:
                # Below the trigram floor, MATCH cannot tokenize the query at
                # all; fall back to the original substring scan so short
                # queries keep working rather than silently returning nothing.
                query = ["SELECT m.* FROM meetings m"]
                clauses = ["m.searchable LIKE ?"]
                parameters: list[Any] = [f"%{normalized}%"]
                if speaker:
                    query.append("JOIN participants p ON p.stem = m.stem AND lower(p.person) LIKE ?")
                    parameters.insert(0, f"%{speaker.lower()}%")
                if date:
                    clauses.append("m.created_at LIKE ?")
                    parameters.append(f"{date}%")
                query.append("WHERE " + " AND ".join(clauses))
                query.append("ORDER BY m.created_at DESC")
                rows = connection.execute(" ".join(query), parameters).fetchall()
                results = []
                for row in rows:
                    metadata = public_metadata_from_row(row, self.read_record(row["stem"]) or {})
                    metadata["snippet"] = plain_snippet(row["searchable"])
                    results.append(metadata)
                return results

            query = [
                "SELECT m.*, snippet(meetings_fts, 0, '', '', ' … ', 12) AS match_snippet",
                "FROM meetings m JOIN meetings_fts ON meetings_fts.rowid = m.rowid",
            ]
            parameters = []
            if speaker:
                query.append("JOIN participants p ON p.stem = m.stem AND lower(p.person) LIKE ?")
                parameters.append(f"%{speaker.lower()}%")
            clauses = ["meetings_fts MATCH ?"]
            parameters.append(fts5_phrase(normalized))
            if date:
                clauses.append("m.created_at LIKE ?")
                parameters.append(f"{date}%")
            query.append("WHERE " + " AND ".join(clauses))
            query.append("ORDER BY bm25(meetings_fts)")
            rows = connection.execute(" ".join(query), parameters).fetchall()
        finally:
            connection.close()
        results = []
        for row in rows:
            metadata = public_metadata_from_row(row, self.read_record(row["stem"]) or {})
            metadata["snippet"] = row["match_snippet"]
            results.append(metadata)
        return results

    def search_people(self, keyword: str) -> list[dict[str, Any]]:
        normalized = nfc(keyword).strip().lower()
        if not normalized:
            return []
        connection = self.connection()
        try:
            if not fts5_available(connection):
                raise SearchBackendUnavailable(
                    "FTS5/trigram search index is unavailable on this sqlite3 build; keyword search cannot run"
                )
            if len(normalized) < TRIGRAM_MINIMUM_LENGTH:
                rows = connection.execute(
                    "SELECT slug, name, meeting_count, notes FROM people"
                    " WHERE lower(name) LIKE ? OR lower(notes) LIKE ? ORDER BY name",
                    (f"%{normalized}%", f"%{normalized}%"),
                ).fetchall()
                return [
                    {
                        "name": row["name"],
                        "slug": row["slug"],
                        "meetingCount": row["meeting_count"],
                        "snippet": plain_snippet(row["notes"]),
                    }
                    for row in rows
                ]
            rows = connection.execute(
                "SELECT p.slug, p.name, p.meeting_count, snippet(people_fts, -1, '', '', ' … ', 12) AS match_snippet"
                " FROM people p JOIN people_fts ON people_fts.rowid = p.rowid"
                " WHERE people_fts MATCH ? ORDER BY bm25(people_fts)",
                (fts5_phrase(normalized),),
            ).fetchall()
        finally:
            connection.close()
        return [
            {"name": row["name"], "slug": row["slug"], "meetingCount": row["meeting_count"], "snippet": row["match_snippet"]}
            for row in rows
        ]

    def read_record(self, stem: str) -> dict[str, Any] | None:
        metadata = self.recordings / stem / "meeting.json"
        if not metadata.is_file():
            return None
        try:
            payload = json.loads(metadata.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None
        if not isinstance(payload, Mapping):
            return None
        record = dict(payload)
        record["stem"] = record.get("stem", stem)
        return record

    def meeting(self, stem: str) -> dict[str, Any] | None:
        record = self.read_record(stem)
        if record is None:
            return None
        summary = record.get("summary")
        if summary is None:
            summary_path = self.recordings / stem / "summary.json"
            if summary_path.is_file():
                try:
                    stored = json.loads(summary_path.read_text(encoding="utf-8"))
                    summary = stored if isinstance(stored, Mapping) else None
                except (OSError, json.JSONDecodeError):
                    summary = None
        return {
            "metadata": public_metadata(record),
            "summary": summary,
            "transcript": record.get("transcript") or [],
        }

    def speaker(self, name: str) -> dict[str, Any] | None:
        normalized = name.casefold()
        profile: str | None = None
        if self.peoples.is_dir():
            for directory in self.peoples.iterdir():
                profile_path = directory / "profile.md"
                if not directory.is_dir() or not profile_path.is_file():
                    continue
                fields, _ = read_profile(profile_path, directory.name, "")
                profile_name = str(fields.get("name", directory.name))
                if profile_name.casefold() == normalized:
                    profile = profile_path.read_text(encoding="utf-8")
                    break
        owner_profile = self.root / "Plaud" / "me" / "profile.md"
        if profile is None and owner_profile.is_file():
            fields, _ = read_profile(owner_profile, "me", "")
            if str(fields.get("name", "me")).casefold() == normalized:
                profile = owner_profile.read_text(encoding="utf-8")
        meetings = self.search(speaker=name)
        if profile is None and not meetings:
            return None
        return {"name": name, "profile": profile, "meetings": meetings}


def public_metadata(record: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "stem": record.get("stem"),
        "title": record.get("title"),
        "displayTitle": record.get("title"),
        "source": record.get("source"),
        "createdAt": record.get("createdAt"),
        "durationSeconds": record.get("durationSeconds"),
        "stage": record.get("stage"),
        "sensitive": bool(record.get("sensitive", False)),
    }


def public_metadata_from_row(row: Any, record: Mapping[str, Any]) -> dict[str, Any]:
    metadata = public_metadata(record)
    metadata["stem"] = record.get("stem") or row["stem"]
    metadata["title"] = record.get("title") or row["title"]
    metadata["displayTitle"] = metadata["title"]
    metadata["source"] = record.get("source") or row["source"]
    metadata["createdAt"] = record.get("createdAt") or row["created_at"]
    if metadata.get("durationSeconds") is None:
        metadata["durationSeconds"] = row["duration_seconds"]
    metadata["stage"] = record.get("stage") or row["stage"]
    return metadata


def dispatch(store: ReadOnlyStore, request: Mapping[str, Any]) -> dict[str, Any]:
    request_id = request.get("id")
    method = request.get("method")
    if method == "tools/list":
        return success(request_id, {"tools": TOOL_DEFINITIONS})
    if method != "tools/call":
        return failure(request_id, -32601, "method not found")
    params = request.get("params") or {}
    tool = params.get("name")
    arguments = params.get("arguments") or {}
    try:
        if tool == "search_meetings":
            payload: Any = store.search(arguments.get("date"), arguments.get("speaker"), arguments.get("keyword"))
        elif tool == "get_meeting":
            payload = store.meeting(arguments.get("stem", ""))
        elif tool == "get_speaker":
            payload = store.speaker(arguments.get("name", ""))
        elif tool == "search_people":
            payload = store.search_people(arguments.get("keyword", ""))
        else:
            return failure(request_id, -32602, "unknown read-only tool")
    except SearchBackendUnavailable as error:
        return failure(request_id, -32000, str(error))
    return success(request_id, {"content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}]})


def success(request_id: Any, result: Mapping[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def failure(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def main() -> int:
    parser = argparse.ArgumentParser(description="Meeting Hub local read-only stdio MCP")
    parser.add_argument("--store", required=True, type=Path)
    args = parser.parse_args()
    store = ReadOnlyStore(args.store)
    if not index_path(store.root).is_file():
        build_index(store.root)
    for line in sys.stdin:
        try:
            request = json.loads(line)
            response = dispatch(store, request)
        except json.JSONDecodeError:
            response = failure(None, -32700, "parse error")
        print(json.dumps(response, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
