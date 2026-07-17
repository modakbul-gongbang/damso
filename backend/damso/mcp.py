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

from .index import build_index, index_path, open_index
from .people import read_profile


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
]


class ReadOnlyStore:
    def __init__(self, root: Path):
        self.root = root.expanduser().resolve()
        self.recordings = self.root / "Plaud" / "recordings"
        self.peoples = self.root / "Plaud" / "peoples"

    def connection(self):
        return open_index(self.root)

    def search(self, date: str | None = None, speaker: str | None = None, keyword: str | None = None) -> list[dict[str, Any]]:
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
        if keyword:
            clauses.append("m.searchable LIKE ?")
            parameters.append(f"%{keyword.lower()}%")
        if clauses:
            query.append("WHERE " + " AND ".join(clauses))
        query.append("ORDER BY m.created_at DESC")
        connection = self.connection()
        try:
            rows = connection.execute(" ".join(query), parameters).fetchall()
        finally:
            connection.close()
        results = []
        for row in rows:
            record = self.read_record(row["stem"]) or {}
            results.append(public_metadata_from_row(row, record))
        return results

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
    if tool == "search_meetings":
        payload: Any = store.search(arguments.get("date"), arguments.get("speaker"), arguments.get("keyword"))
    elif tool == "get_meeting":
        payload = store.meeting(arguments.get("stem", ""))
    elif tool == "get_speaker":
        payload = store.speaker(arguments.get("name", ""))
    else:
        return failure(request_id, -32602, "unknown read-only tool")
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
