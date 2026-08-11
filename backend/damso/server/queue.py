"""The single server-owned processing queue (R3, D-13).

Replaces the two-source-of-truth split the SSH era had (the client
ssh-invoking `damso.processing` for its own fresh recordings, plus a
separate server-side sweep for backlog): every recording's phase-one and
summary steps go through this one queue regardless of how the recording
arrived (fresh upload, Plaud import, or a server restart finding unfinished
work). A background worker thread drains it; `requeue()` is the only way a
failed job runs again (no automatic retries, matching the existing local
processing error contract: an explicit user action, not a silent retry).
"""

from __future__ import annotations

import datetime as dt
import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Callable

from .. import processing, summary

AUDIO_EXTENSIONS = (".caf", ".m4a", ".wav", ".mp3")

PhaseOneRunner = Callable[[dict[str, Any]], dict[str, Any]]
SummaryRunner = Callable[[dict[str, Any]], dict[str, Any]]


class QueueError(RuntimeError):
    pass


def _connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(db_path, check_same_thread=False)
    connection.row_factory = sqlite3.Row
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            stem TEXT NOT NULL,
            kind TEXT NOT NULL,
            state TEXT NOT NULL,
            payload TEXT NOT NULL,
            error TEXT,
            updated_at TEXT NOT NULL
        )
        """
    )
    connection.execute("CREATE INDEX IF NOT EXISTS jobs_stem_idx ON jobs (stem)")
    connection.commit()
    return connection


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


class ProcessingQueue:
    def __init__(
        self,
        db_path: Path,
        store_root: Path,
        *,
        phase_one_runner: PhaseOneRunner | None = None,
        summary_runner: SummaryRunner | None = None,
        poll_interval: float = 0.5,
    ) -> None:
        self._store_root = store_root
        self._phase_one_runner = phase_one_runner or processing.execute_request
        self._summary_runner = summary_runner or summary.execute_request
        self._poll_interval = poll_interval
        self._lock = threading.Lock()
        self._connection = _connect(db_path)
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None

    # -- lifecycle -----------------------------------------------------

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._worker_loop, name="damso-processing-queue", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=5)
            self._thread = None

    def recover_incomplete_on_startup(self) -> None:
        """A job left `running` when the process last stopped (crash, kill
        -9) never finished; the file it was writing to is either absent or
        an in-progress artifact set that the next attempt will overwrite, so
        it is safe - and necessary - to requeue it rather than leave it
        stuck forever."""
        with self._lock:
            self._connection.execute(
                "UPDATE jobs SET state = 'queued', updated_at = ? WHERE state = 'running'", (_now(),)
            )
            self._connection.commit()

    # -- enqueue / requeue ----------------------------------------------

    def enqueue_phase_one(self, stem: str) -> None:
        self._insert(stem, "phase-one", {})

    def enqueue_summary(self, stem: str, *, agent: str = "claude", language: str = "ko", meeting_date: str | None = None) -> None:
        self._insert(stem, "summary", {"agent": agent, "language": language, "meeting_date": meeting_date})

    def requeue(self, stem: str) -> bool:
        with self._lock:
            row = self._connection.execute(
                "SELECT id FROM jobs WHERE stem = ? AND state = 'failed' ORDER BY id DESC LIMIT 1", (stem,)
            ).fetchone()
            if row is None:
                return False
            self._connection.execute(
                "UPDATE jobs SET state = 'queued', error = NULL, updated_at = ? WHERE id = ?", (_now(), row["id"])
            )
            self._connection.commit()
            return True

    def status(self, stem: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT kind, state, error, updated_at FROM jobs WHERE stem = ? ORDER BY id DESC LIMIT 1", (stem,)
            ).fetchone()
        if row is None:
            return None
        return {"stem": stem, "kind": row["kind"], "state": row["state"], "error": row["error"], "updatedAt": row["updated_at"]}

    def _insert(self, stem: str, kind: str, payload: dict[str, Any]) -> None:
        with self._lock:
            self._connection.execute(
                "INSERT INTO jobs (stem, kind, state, payload, error, updated_at) VALUES (?, ?, 'queued', ?, NULL, ?)",
                (stem, kind, json.dumps(payload), _now()),
            )
            self._connection.commit()

    # -- worker ----------------------------------------------------------

    def _worker_loop(self) -> None:
        while not self._stop_event.is_set():
            job = self._claim_next()
            if job is None:
                self._stop_event.wait(self._poll_interval)
                continue
            self._run(job)

    def _claim_next(self) -> sqlite3.Row | None:
        with self._lock:
            row = self._connection.execute(
                "SELECT * FROM jobs WHERE state = 'queued' ORDER BY id ASC LIMIT 1"
            ).fetchone()
            if row is None:
                return None
            self._connection.execute(
                "UPDATE jobs SET state = 'running', updated_at = ? WHERE id = ?", (_now(), row["id"])
            )
            self._connection.commit()
        return row

    def _run(self, job: sqlite3.Row) -> None:
        try:
            if job["kind"] == "phase-one":
                self._run_phase_one(job["stem"])
            elif job["kind"] == "summary":
                self._run_summary(job["stem"], json.loads(job["payload"]))
            else:
                raise QueueError(f"unknown job kind: {job['kind']!r}")
        except Exception as error:  # noqa: BLE001 - a job failure must never kill the worker thread
            self._mark(job["id"], "failed", error=str(error))
            return
        self._mark(job["id"], "done")

    def _mark(self, job_id: int, state: str, *, error: str | None = None) -> None:
        with self._lock:
            self._connection.execute(
                "UPDATE jobs SET state = ?, error = ?, updated_at = ? WHERE id = ?", (state, error, _now(), job_id)
            )
            self._connection.commit()

    def _run_phase_one(self, stem: str) -> None:
        recording_directory = self._store_root / "Plaud" / "recordings" / stem
        audio_path, system_audio_path = _detect_audio_files(recording_directory)
        record = _read_record(recording_directory)
        record_hints = record.get("hints") if isinstance(record.get("hints"), dict) else {}
        request = {
            "operation": "phase-one",
            "recording_directory": str(recording_directory),
            "audio_path": str(audio_path),
            "system_audio_path": str(system_audio_path) if system_audio_path else None,
            "hints": {
                "participants": record_hints.get("participants", []),
                "domain_terms": record_hints.get("domainTerms", []),
                "topic": record_hints.get("topic"),
                "num_speakers": record_hints.get("numSpeakers"),
            },
        }
        result = self._phase_one_runner(request)
        if not result.get("ok"):
            raise QueueError(result.get("error", {}).get("message", "phase-one failed"))

    def _run_summary(self, stem: str, payload: dict[str, Any]) -> None:
        recording_directory = self._store_root / "Plaud" / "recordings" / stem
        request = {
            "operation": "summary",
            "recording_directory": str(recording_directory),
            "agent": payload.get("agent", "claude"),
            "language": payload.get("language", "ko"),
            "meeting_date": payload.get("meeting_date"),
        }
        result = self._summary_runner(request)
        # `damso.summary` uses `ok` for "the request itself was processed"
        # and reports the actual outcome in `status` (SSH-era contract:
        # `agent_cli_missing`, budget refusals, ... all come back as
        # `ok: True, status: "failed", error_code: ...`). Checking `ok`
        # alone marked those jobs done, so the client showed a completed
        # summary stage while summary.json was never rewritten (found via a
        # real two-machine run: the server's launchd PATH had no claude CLI,
        # every summary silently "succeeded" in one second, and nothing
        # anywhere surfaced agent_cli_missing).
        if not result.get("ok") or result.get("status") != "complete":
            raise QueueError(str(result.get("error_code") or "summary failed"))


def _read_record(recording_directory: Path) -> dict[str, Any]:
    record_path = recording_directory / "meeting.json"
    if not record_path.is_file():
        return {}
    try:
        payload = json.loads(record_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return payload if isinstance(payload, dict) else {}


def _detect_audio_files(recording_directory: Path) -> tuple[Path, Path | None]:
    candidates = sorted(
        entry
        for entry in recording_directory.iterdir()
        if entry.is_file() and not entry.is_symlink() and entry.suffix.lower() in AUDIO_EXTENSIONS
    )
    if not candidates:
        raise QueueError("no audio file found in the recording directory")
    if len(candidates) == 1:
        return candidates[0], None
    if len(candidates) > 2:
        raise QueueError("more than two audio files found; cannot determine primary vs system audio")
    primary = next((c for c in candidates if c.stem.lower().startswith("microphone")), candidates[0])
    secondary = next(c for c in candidates if c != primary)
    return primary, secondary
