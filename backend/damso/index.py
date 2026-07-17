"""Rebuildable SQLite search index over the canonical file store.

The files under ``Plaud/recordings`` and ``Plaud/peoples`` remain the only
source of truth. This module derives ``index.sqlite3`` at the store root for
fast meeting/people/relation search (used by the MCP server and diagnostics),
and a full rebuild from files is deterministic: no LLM call, no network, and
no data that exists only in the database.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import sqlite3
import sys
from pathlib import Path
from typing import Any, Iterable, Mapping

from .duplicates import detect_candidates
from .people import read_profile

INDEX_FILENAME = "index.sqlite3"
SCHEMA_VERSION = 1

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE meetings (
    stem TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    source TEXT NOT NULL,
    created_at TEXT NOT NULL,
    duration_seconds REAL,
    stage TEXT NOT NULL,
    summary_one_line TEXT,
    searchable TEXT NOT NULL
);
CREATE TABLE participants (
    stem TEXT NOT NULL,
    person TEXT NOT NULL,
    speaker_label TEXT NOT NULL,
    PRIMARY KEY (stem, person, speaker_label)
);
CREATE TABLE people (
    slug TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    meeting_count INTEGER NOT NULL,
    first_seen TEXT,
    last_seen TEXT,
    has_voice_profile INTEGER NOT NULL
);
CREATE TABLE duplicate_candidates (
    stem_a TEXT NOT NULL,
    stem_b TEXT NOT NULL,
    start_delta_seconds REAL NOT NULL,
    duration_delta_seconds REAL NOT NULL,
    PRIMARY KEY (stem_a, stem_b)
);
CREATE INDEX meetings_created_at ON meetings (created_at);
CREATE INDEX participants_person ON participants (person);
"""


def index_path(store_root: Path) -> Path:
    return store_root / INDEX_FILENAME


def load_meeting_files(store_root: Path) -> list[dict[str, Any]]:
    recordings = store_root / "Plaud" / "recordings"
    if not recordings.is_dir():
        return []
    records = []
    for directory in sorted(recordings.iterdir()):
        metadata = directory / "meeting.json"
        if not directory.is_dir() or not metadata.is_file():
            continue
        try:
            payload = json.loads(metadata.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(payload, Mapping):
            continue
        record = dict(payload)
        record["stem"] = str(record.get("stem", directory.name))
        record["_directory"] = directory
        records.append(record)
    return records


def transcript_text(directory: Path) -> str:
    for name in ("transcript.json", "transcript.raw.json"):
        path = directory / name
        if not path.is_file():
            continue
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        segments = payload.get("segments") if isinstance(payload, Mapping) else None
        if isinstance(segments, list):
            return " ".join(str(item.get("text", "")) for item in segments if isinstance(item, Mapping))
    return ""


def captured_participant_names(directory: Path) -> list[str]:
    """Display names captured live into participants.json (may be absent)."""
    path = directory / "participants.json"
    if not path.is_file():
        return []
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    entries = payload.get("participants") if isinstance(payload, Mapping) else None
    if not isinstance(entries, list):
        return []
    names = []
    for entry in entries:
        if isinstance(entry, Mapping):
            name = str(entry.get("name") or "").strip()
            if name:
                names.append(name)
    return names


def summary_payload(directory: Path) -> Mapping[str, Any] | None:
    path = directory / "summary.json"
    if not path.is_file():
        return None
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, Mapping) else None


def build_index(store_root: Path, db_path: Path | None = None) -> dict[str, Any]:
    store_root = store_root.expanduser().resolve()
    destination = db_path or index_path(store_root)
    temporary = destination.with_name(destination.name + ".rebuild")
    temporary.unlink(missing_ok=True)

    records = load_meeting_files(store_root)
    connection = sqlite3.connect(temporary)
    try:
        connection.executescript(SCHEMA)
        connection.execute("INSERT INTO meta (key, value) VALUES ('schema_version', ?)", (str(SCHEMA_VERSION),))

        for record in records:
            directory = record["_directory"]
            summary = summary_payload(directory)
            summary_text = json.dumps(summary, ensure_ascii=False) if summary else ""
            searchable = " ".join(
                part
                for part in [
                    str(record.get("title", "")),
                    summary_text,
                    transcript_text(directory),
                    " ".join(captured_participant_names(directory)),
                ]
                if part
            ).lower()
            connection.execute(
                "INSERT INTO meetings (stem, title, source, created_at, duration_seconds, stage, summary_one_line, searchable)"
                " VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    record["stem"],
                    str(record.get("title", "")),
                    str(record.get("source", "")),
                    str(record.get("createdAt", "")),
                    record.get("durationSeconds"),
                    str(record.get("stage", "")),
                    str((summary or {}).get("one_line_summary", "")) or None,
                    searchable,
                ),
            )
            for resolution in record.get("resolutions", []) or []:
                if not isinstance(resolution, Mapping) or resolution.get("action") == "skip":
                    continue
                person = str(resolution.get("personName") or "").strip()
                if not person:
                    continue
                connection.execute(
                    "INSERT OR IGNORE INTO participants (stem, person, speaker_label) VALUES (?, ?, ?)",
                    (record["stem"], person, str(resolution.get("speaker", ""))),
                )

        for slug, fields, directory in iter_people(store_root):
            connection.execute(
                "INSERT OR REPLACE INTO people (slug, name, meeting_count, first_seen, last_seen, has_voice_profile)"
                " VALUES (?, ?, ?, ?, ?, ?)",
                (
                    slug,
                    str(fields.get("name") or slug),
                    int(fields.get("meeting_count") or 0),
                    fields.get("first_seen"),
                    fields.get("last_seen"),
                    1 if (directory / "voice.npy").is_file() else 0,
                ),
            )

        for candidate in safe_duplicate_candidates(records):
            connection.execute(
                "INSERT OR IGNORE INTO duplicate_candidates (stem_a, stem_b, start_delta_seconds, duration_delta_seconds)"
                " VALUES (?, ?, ?, ?)",
                (candidate.first.stem, candidate.second.stem, candidate.start_delta_seconds, candidate.duration_delta_seconds),
            )
        connection.commit()
    finally:
        connection.close()

    temporary.replace(destination)
    return {
        "ok": True,
        "database": str(destination),
        "meetings": len(records),
        "built_from": str(store_root),
    }


def iter_people(store_root: Path) -> Iterable[tuple[str, Mapping[str, Any], Path]]:
    peoples = store_root / "Plaud" / "peoples"
    directories = []
    if peoples.is_dir():
        # peoples/archive holds absorbed profiles preserved by merge; they are
        # not active people and must not resurface in the index.
        directories.extend(item for item in peoples.iterdir() if item.is_dir() and item.name != "archive")
    me = store_root / "Plaud" / "me"
    if me.is_dir():
        directories.append(me)
    today = dt.date.today().isoformat()
    for directory in sorted(directories, key=lambda item: item.name):
        fields, _ = read_profile(directory / "profile.md", directory.name, today)
        yield directory.name, fields, directory


def safe_duplicate_candidates(records: list[dict[str, Any]]):
    cleaned = []
    for record in records:
        try:
            candidate = {key: value for key, value in record.items() if key != "_directory"}
            from .duplicates import fingerprint

            fingerprint(candidate)
            cleaned.append(candidate)
        except (ValueError, TypeError):
            continue
    try:
        return detect_candidates(cleaned)
    except (ValueError, TypeError):
        return []


def open_index(store_root: Path, *, rebuild_if_missing: bool = True) -> sqlite3.Connection:
    store_root = store_root.expanduser().resolve()
    path = index_path(store_root)
    if not path.is_file() and rebuild_if_missing:
        build_index(store_root)
    connection = sqlite3.connect(path)
    connection.row_factory = sqlite3.Row
    return connection


def main() -> int:
    parser = argparse.ArgumentParser(description="Rebuild the Meeting Hub SQLite search index from canonical files")
    parser.add_argument("--store", required=True, type=Path)
    parser.add_argument("--db", type=Path, default=None)
    args = parser.parse_args()
    try:
        result = build_index(args.store, args.db)
    except OSError as error:
        sys.stdout.write(json.dumps({"ok": False, "error": str(error)}) + "\n")
        return 1
    sys.stdout.write(json.dumps(result, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
