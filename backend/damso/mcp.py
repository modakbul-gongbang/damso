"""Read-only local stdio MCP server for canonical Damso records.

Search runs against the rebuildable SQLite index (``index.sqlite3``) derived
from the file store, while full meeting and profile payloads are still read
from the canonical files. The three tool names and their existing response
fields are stable; new fields are only ever added, never renamed or removed.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from pathlib import Path
from typing import Any, Mapping

from .index import build_index, index_path, nfc, open_index
from .people import read_profile
from .transcript_cleanup import read_effective_transcript


# Below this, the trigram tokenizer produces zero tokens for the query term
# (each token is 3 characters), so an FTS5 MATCH against it always returns
# zero rows regardless of what the index contains. search()/search_people()
# fall back to a plain substring LIKE scan under this length instead.
TRIGRAM_MINIMUM_LENGTH = 3

# R8: search_meetings/search_people returned every match with no cap - a
# store with years of meetings could return a response an AI client has to
# read in full before it can do anything else. `limit` defaults small enough
# to keep a single call cheap; `offset` lets a caller page through the rest.
DEFAULT_SEARCH_LIMIT = 20
MAX_SEARCH_LIMIT = 100


# MCP revisions this server can speak. A client announces the revision it
# wants in `initialize`; the spec says answer with that same revision when we
# support it, and with our own latest when we do not, so the client can decide
# whether to continue. Ordered newest first - the head is what we advertise.
SUPPORTED_PROTOCOL_VERSIONS = ("2025-06-18", "2025-03-26", "2024-11-05")
PROTOCOL_VERSION = SUPPORTED_PROTOCOL_VERSIONS[0]


class SearchBackendUnavailable(RuntimeError):
    """Raised when a keyword search is requested but the FTS5 trigram index could not be built."""


class InvalidSearchArgument(ValueError):
    """Raised when a search argument is well-formed JSON but not a value the
    query can act on (R5) - a malformed `date` used to be silently treated as
    a `LIKE` prefix that matched nothing, indistinguishable from "correctly
    formatted but genuinely zero results"."""


# `created_at` is matched with a `LIKE '{date}%'` prefix, so the only values
# that can ever match anything are a year, a year-month, or a full date.
DATE_ARGUMENT_SHAPE = re.compile(r"^\d{4}(-\d{2}(-\d{2})?)?$")


def validate_date_argument(value: str | None, *, field: str) -> None:
    """Shape alone (`\\d{4}(-\\d{2}(-\\d{2})?)?`) still lets "2026-13" or
    "2026-02-30" through - real month/day bounds need an actual calendar
    check, not just digit counting."""
    if value is None:
        return
    if not DATE_ARGUMENT_SHAPE.match(value):
        raise InvalidSearchArgument(f"{field} must be formatted YYYY, YYYY-MM, or YYYY-MM-DD (got {value!r})")
    parts = value.split("-")
    year = int(parts[0])
    month = int(parts[1]) if len(parts) >= 2 else 1
    day = int(parts[2]) if len(parts) >= 3 else 1
    try:
        dt.date(year, month, day)
    except ValueError as error:
        raise InvalidSearchArgument(f"{field} must be a valid calendar date (got {value!r})") from error


def date_range_clauses(date: str | None, date_from: str | None, date_to: str | None) -> tuple[list[str], list[Any]]:
    """R12: `date` stays a single-prefix filter (unchanged); `from`/`to` add
    an inclusive range. Combining `date` with either is rejected rather than
    given an implicit precedence rule a caller would have to guess at.
    Comparing ISO-8601 strings lexicographically already equals chronological
    order, and a shorter prefix always sorts before any longer string sharing
    it - so a bare `>= date_from` is already an inclusive lower bound with no
    date-arithmetic needed. The upper bound needs one trick: `<= date_to`
    alone would exclude every timestamp within that day/month/year except an
    exact prefix match, since "2026-07-14T09:00Z" sorts after "2026-07-14";
    appending U+FFFF (the maximum codepoint) makes the prefix compare as
    "the end of that day/month/year" instead.
    """
    validate_date_argument(date, field="date")
    validate_date_argument(date_from, field="from")
    validate_date_argument(date_to, field="to")
    if date and (date_from or date_to):
        raise InvalidSearchArgument("date cannot be combined with from/to - use date alone, or from/to for a range")
    clauses: list[str] = []
    parameters: list[Any] = []
    if date:
        clauses.append("m.created_at LIKE ?")
        parameters.append(f"{date}%")
    if date_from:
        clauses.append("m.created_at >= ?")
        parameters.append(date_from)
    if date_to:
        clauses.append("m.created_at <= ?")
        parameters.append(date_to + "￿")
    return clauses, parameters


def resolve_pagination(limit: Any, offset: Any) -> tuple[int, int]:
    resolved_limit = DEFAULT_SEARCH_LIMIT if limit is None else limit
    if not isinstance(resolved_limit, int) or isinstance(resolved_limit, bool) or not (1 <= resolved_limit <= MAX_SEARCH_LIMIT):
        raise InvalidSearchArgument(f"limit must be an integer from 1 to {MAX_SEARCH_LIMIT} (got {limit!r})")
    resolved_offset = 0 if offset is None else offset
    if not isinstance(resolved_offset, int) or isinstance(resolved_offset, bool) or resolved_offset < 0:
        raise InvalidSearchArgument(f"offset must be a non-negative integer (got {offset!r})")
    return resolved_limit, resolved_offset


TOOL_DEFINITIONS = [
    {
        "name": "search_meetings",
        "description": (
            "Search local meetings by date, date range, speaker, and/or keyword; combine any of them to "
            "narrow the results. Returns metadata only (title, stem, createdAt, stage, ...) - call "
            "get_meeting with a result's `stem` to read its summary and transcript. Results are newest-first "
            "unless `keyword` is set, in which case they are ranked by keyword relevance and each item gets "
            "a `snippet` showing the matched text. `speaker` matches loosely (a substring of the resolved "
            "participant name) for browsing when you don't know the exact name - get_speaker's own `meetings` "
            "list is the exact-match version for a specific, already-identified person."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "date": {
                    "type": "string",
                    "description": "Restrict to one year, month, or day: 'YYYY', 'YYYY-MM', or 'YYYY-MM-DD'. Cannot be combined with from/to.",
                },
                "from": {
                    "type": "string",
                    "description": "Inclusive start of a date range, same format as `date`. Use with `to` for a range; omit `to` for open-ended.",
                },
                "to": {
                    "type": "string",
                    "description": "Inclusive end of a date range, same format as `date` (a whole year/month/day, not a timestamp). Use with `from` for a range; omit `from` for open-ended.",
                },
                "speaker": {
                    "type": "string",
                    "description": "Substring match against a resolved participant's name (case-insensitive). For browsing, not exact identification.",
                },
                "keyword": {
                    "type": "string",
                    "description": "Full-text keyword search over meeting titles, summaries, and transcripts. Ranked by relevance; each result includes a matching `snippet`. Works for Korean and English.",
                },
                "limit": {
                    "type": "integer",
                    "description": f"Maximum results to return, {1}-{MAX_SEARCH_LIMIT}. Defaults to {DEFAULT_SEARCH_LIMIT}. If you get exactly `limit` results, there may be more - retry with a higher `offset`.",
                },
                "offset": {
                    "type": "integer",
                    "description": "How many matching results to skip before returning `limit` of them, for paging past the first page. Defaults to 0.",
                },
            },
        },
        "annotations": {"readOnlyHint": True, "idempotentHint": True, "openWorldHint": False},
    },
    {
        "name": "get_meeting",
        "description": (
            "Get the full detail of one specific local meeting: metadata, the stored summary, and the "
            "complete transcript (with any confirmed text cleanup already applied). Requires `stem`, which "
            "is not a title you type - it is the machine identifier a search_meetings result returns for "
            "that meeting; find the meeting there first."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "stem": {"type": "string", "description": "A meeting identifier as returned by search_meetings, e.g. '2026-08-11T09-30-00Z_abcdef'."},
            },
            "required": ["stem"],
        },
        "annotations": {"readOnlyHint": True, "idempotentHint": True, "openWorldHint": False},
    },
    {
        "name": "get_speaker",
        "description": (
            "Get one local person's profile notes and the exact list of meetings they are credited in "
            "(exact identity match, not a substring search - if you only have a partial or uncertain name, "
            "call search_people first to find the right one)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {"type": "string", "description": "The person's exact resolved name, case-insensitive (e.g. from a search_people or search_meetings result)."},
            },
            "required": ["name"],
        },
        "annotations": {"readOnlyHint": True, "idempotentHint": True, "openWorldHint": False},
    },
    {
        "name": "search_people",
        "description": (
            "Search local people by name or by their free-text profile notes when you don't know someone's "
            "exact name. Returns candidates with a relevance `snippet` - call get_speaker with a result's "
            "`name` for that person's full profile and meeting history."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "keyword": {"type": "string", "description": "Matched against the person's name and their profile Notes text. Works for Korean and English."},
                "limit": {
                    "type": "integer",
                    "description": f"Maximum results to return, {1}-{MAX_SEARCH_LIMIT}. Defaults to {DEFAULT_SEARCH_LIMIT}. If you get exactly `limit` results, there may be more - retry with a higher `offset`.",
                },
                "offset": {
                    "type": "integer",
                    "description": "How many matching results to skip before returning `limit` of them, for paging past the first page. Defaults to 0.",
                },
            },
            "required": ["keyword"],
        },
        "annotations": {"readOnlyHint": True, "idempotentHint": True, "openWorldHint": False},
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

    def search(
        self,
        date: str | None = None,
        speaker: str | None = None,
        keyword: str | None = None,
        *,
        date_from: str | None = None,
        date_to: str | None = None,
        limit: Any = None,
        offset: Any = None,
    ) -> list[dict[str, Any]]:
        resolved_limit, resolved_offset = resolve_pagination(limit, offset)
        if keyword:
            return self._search_by_keyword(date, speaker, keyword, date_from, date_to, resolved_limit, resolved_offset)
        return self._search_without_keyword(date, speaker, date_from, date_to, resolved_limit, resolved_offset)

    def _search_without_keyword(
        self, date: str | None, speaker: str | None, date_from: str | None, date_to: str | None, limit: int, offset: int
    ) -> list[dict[str, Any]]:
        query = ["SELECT m.* FROM meetings m"]
        parameters: list[Any] = []
        if speaker:
            query.append(
                "JOIN participants p ON p.stem = m.stem AND lower(p.person) LIKE ?"
            )
            parameters.append(f"%{speaker.lower()}%")
        clauses, date_parameters = date_range_clauses(date, date_from, date_to)
        parameters.extend(date_parameters)
        if clauses:
            query.append("WHERE " + " AND ".join(clauses))
        query.append("ORDER BY m.created_at DESC LIMIT ? OFFSET ?")
        parameters.extend([limit, offset])
        connection = self.connection()
        try:
            rows = connection.execute(" ".join(query), parameters).fetchall()
        finally:
            connection.close()
        return [public_metadata_from_row(row, self.read_record(row["stem"]) or {}) for row in rows]

    def _search_by_keyword(
        self,
        date: str | None,
        speaker: str | None,
        keyword: str,
        date_from: str | None,
        date_to: str | None,
        limit: int,
        offset: int,
    ) -> list[dict[str, Any]]:
        normalized = nfc(keyword).strip().lower()
        if not normalized:
            return self._search_without_keyword(date, speaker, date_from, date_to, limit, offset)
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
                date_clauses, date_parameters = date_range_clauses(date, date_from, date_to)
                clauses.extend(date_clauses)
                parameters.extend(date_parameters)
                query.append("WHERE " + " AND ".join(clauses))
                query.append("ORDER BY m.created_at DESC LIMIT ? OFFSET ?")
                parameters.extend([limit, offset])
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
            date_clauses, date_parameters = date_range_clauses(date, date_from, date_to)
            clauses.extend(date_clauses)
            parameters.extend(date_parameters)
            query.append("WHERE " + " AND ".join(clauses))
            query.append("ORDER BY bm25(meetings_fts) LIMIT ? OFFSET ?")
            parameters.extend([limit, offset])
            rows = connection.execute(" ".join(query), parameters).fetchall()
        finally:
            connection.close()
        results = []
        for row in rows:
            metadata = public_metadata_from_row(row, self.read_record(row["stem"]) or {})
            metadata["snippet"] = row["match_snippet"]
            results.append(metadata)
        return results

    def search_people(self, keyword: str, *, limit: Any = None, offset: Any = None) -> list[dict[str, Any]]:
        resolved_limit, resolved_offset = resolve_pagination(limit, offset)
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
                    " WHERE lower(name) LIKE ? OR lower(notes) LIKE ? ORDER BY name LIMIT ? OFFSET ?",
                    (f"%{normalized}%", f"%{normalized}%", resolved_limit, resolved_offset),
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
                " WHERE people_fts MATCH ? ORDER BY bm25(people_fts) LIMIT ? OFFSET ?",
                (fts5_phrase(normalized), resolved_limit, resolved_offset),
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
        # R4: `meeting.json` never carries the transcript itself (it lives in
        # `transcript.json`/`transcript.raw.json`, with any cleanup
        # corrections layered on separately) - `record.get("transcript")`
        # here always returned an empty list, silently breaking the promise
        # this tool's own description makes.
        effective_transcript = read_effective_transcript(self.recordings / stem)
        segments = effective_transcript.get("segments") if effective_transcript else None
        return {
            "metadata": public_metadata(record),
            "summary": summary,
            "transcript": segments if isinstance(segments, list) else [],
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
        meetings = self._meetings_credited_to(name)
        if profile is None and not meetings:
            return None
        return {"name": name, "profile": profile, "meetings": meetings}

    def _meetings_credited_to(self, name: str) -> list[dict[str, Any]]:
        """R7: exact match, unlike `search(speaker=...)`'s deliberately loose
        substring match. `participants.person` is not a raw live-captured
        display name (that's `participants.json`, used only for keyword
        search's free-text blob) - it comes from `meeting.json`'s own
        `resolutions` (build_index in index.py), i.e. it is already the
        resolved, canonical person name. A substring match against an
        already-canonical name column only ever adds false positives: asking
        for a common single-syllable name like "이" doesn't just fail to find
        a profile, it silently attaches every meeting where *any* unrelated
        person's resolved name happens to contain that substring."""
        normalized = name.strip().lower()
        connection = self.connection()
        try:
            rows = connection.execute(
                "SELECT m.* FROM meetings m JOIN participants p ON p.stem = m.stem AND lower(p.person) = ?"
                " ORDER BY m.created_at DESC",
                (normalized,),
            ).fetchall()
        finally:
            connection.close()
        return [public_metadata_from_row(row, self.read_record(row["stem"]) or {}) for row in rows]


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


def server_info() -> dict[str, str]:
    try:
        from importlib import metadata as importlib_metadata

        version = importlib_metadata.version("damso")
    except Exception:
        version = "0"
    return {"name": "damso", "version": version}


# R10: a per-tool description can explain that one tool, but not the
# relationship between tools - that search_meetings/search_people return a
# `stem`/`name` meant to be fed straight into get_meeting/get_speaker is a
# server-wide fact, so it belongs in `initialize`'s `instructions`, the one
# thing every MCP client reads before its first tool call.
SERVER_INSTRUCTIONS = (
    "Read-only access to a local meeting store. All four tools are read-only and change nothing. "
    "Typical use is two calls: search first (search_meetings or search_people) to find a candidate, "
    "then read (get_meeting or get_speaker) using the exact `stem`/`name` the search result gave you - "
    "those values are opaque identifiers from this store, not something to guess or type from a title. "
    "search_meetings/search_people return only metadata plus a match `snippet`, capped at a small page by "
    "default (see each tool's `limit`/`offset`); get_meeting/get_speaker return the full detail for one item. "
    "A search or lookup that finds nothing returns an empty list or a tool error explaining why, never a "
    "silent guess."
)


def initialize_result(params: Mapping[str, Any]) -> dict[str, Any]:
    requested = params.get("protocolVersion")
    negotiated = requested if requested in SUPPORTED_PROTOCOL_VERSIONS else PROTOCOL_VERSION
    return {
        "protocolVersion": negotiated,
        # Tools only: this server has no prompts, resources, or sampling, and
        # advertising a capability it cannot serve would make a client offer
        # the user something that then fails.
        "capabilities": {"tools": {}},
        "serverInfo": server_info(),
        "instructions": SERVER_INSTRUCTIONS,
    }


def dispatch(store: ReadOnlyStore, request: Mapping[str, Any]) -> dict[str, Any] | None:
    """Returns the JSON-RPC response, or None for a notification, which by
    definition takes no reply."""
    request_id = request.get("id")
    method = request.get("method")
    is_notification = "id" not in request

    # The handshake every MCP client performs before it will use any tool.
    # Without it a compliant client never gets as far as `tools/list`.
    if method == "initialize":
        return success(request_id, initialize_result(request.get("params") or {}))
    if is_notification:
        # `notifications/initialized` and friends: acknowledged by silence.
        return None
    if method == "ping":
        return success(request_id, {})
    if method == "tools/list":
        return success(request_id, {"tools": TOOL_DEFINITIONS})
    if method != "tools/call":
        return failure(request_id, -32601, "method not found")
    params = request.get("params") or {}
    tool = params.get("name")
    arguments = params.get("arguments") or {}
    try:
        if tool == "search_meetings":
            payload: Any = store.search(
                arguments.get("date"),
                arguments.get("speaker"),
                arguments.get("keyword"),
                date_from=arguments.get("from"),
                date_to=arguments.get("to"),
                limit=arguments.get("limit"),
                offset=arguments.get("offset"),
            )
        elif tool == "get_meeting":
            stem = arguments.get("stem", "")
            payload = store.meeting(stem)
            if payload is None:
                # R6: `stem` is a machine key from a search_meetings result,
                # not a title a caller might type by hand - a bare `null`
                # here read the same as "this tool is broken" and gave no
                # hint about what to try instead.
                return success(request_id, tool_error(
                    f"no meeting found with stem {stem!r}. `stem` must be a value returned by search_meetings, not a meeting title."
                ))
        elif tool == "get_speaker":
            name = arguments.get("name", "")
            payload = store.speaker(name)
            if payload is None:
                return success(request_id, tool_error(
                    f"no speaker found named {name!r}: no matching profile and no meeting credits that exact name. Try search_people first to find the right name."
                ))
        elif tool == "search_people":
            payload = store.search_people(arguments.get("keyword", ""), limit=arguments.get("limit"), offset=arguments.get("offset"))
        else:
            return failure(request_id, -32602, "unknown read-only tool")
    except SearchBackendUnavailable as error:
        return failure(request_id, -32000, str(error))
    except InvalidSearchArgument as error:
        # A malformed argument value, not a protocol-level problem - the
        # call itself was well-formed JSON-RPC, so this stays inside a
        # successful tool result (MCP's own `isError`) rather than a
        # JSON-RPC `error`, matching the spec's split between "the request
        # was invalid" and "the tool ran but the operation failed".
        return success(request_id, tool_error(str(error)))
    return success(request_id, {"content": [{"type": "text", "text": json.dumps(payload, ensure_ascii=False)}]})


def tool_error(message: str) -> dict[str, Any]:
    return {"content": [{"type": "text", "text": message}], "isError": True}


def success(request_id: Any, result: Mapping[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def failure(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def main() -> int:
    parser = argparse.ArgumentParser(description="Damso local read-only stdio MCP")
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
        if response is None:
            continue  # a notification takes no reply
        print(json.dumps(response, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
