"""Local request boundary for automatic agent-CLI meeting summaries.

The macOS app passes a canonical record directory plus the selected agent and
output language. This module reads the already-produced local transcript from
that directory, uses the selected sandboxed agent boundary (Claude Code or
Codex), and writes a bounded ``summary.json`` (including the generated title
and person-note proposals) back to that same record. Transcript text never
travels back over stdout.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Callable, Mapping

from .agent_boundary import SUPPORTED_AGENTS, SUPPORTED_LANGUAGES, BoundaryResult, make_boundary
from .contracts import atomic_write_json
from .processing import MAX_REQUEST_BYTES, ProcessingError, canonical_recording_directory


class SummaryError(RuntimeError):
    pass


def execute_request(
    request: Mapping[str, Any],
    *,
    boundary_factory: Callable[[str, Path], Any] | None = None,
) -> dict[str, Any]:
    recording_directory = canonical_recording_directory(request.get("recording_directory"))
    agent = request.get("agent", "claude")
    if agent not in SUPPORTED_AGENTS:
        raise SummaryError("agent must be claude or codex")
    language = request.get("language", "ko")
    if language not in SUPPORTED_LANGUAGES:
        raise SummaryError("language must be ko or en")

    transcript_path = recording_directory / "transcript.json"
    if not transcript_path.is_file():
        transcript_path = recording_directory / "transcript.raw.json"
    if not transcript_path.is_file():
        raise SummaryError("a local transcript is required before requesting a summary")
    try:
        transcript = json.loads(transcript_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SummaryError("the local transcript is unreadable") from error
    if not isinstance(transcript, Mapping):
        raise SummaryError("the local transcript is invalid")

    if boundary_factory is None:
        boundary_factory = make_boundary
    try:
        boundary = boundary_factory(agent, recording_directory.parent.parent)
    except FileNotFoundError:
        return {"ok": True, "status": "failed", "error_code": "agent_cli_missing"}
    result = boundary.run_summary(transcript, language=language)
    return persist_result(recording_directory, result)


def persist_result(recording_directory: Path, result: BoundaryResult) -> dict[str, Any]:
    if result.status == "complete" and result.summary is not None:
        atomic_write_json(recording_directory / "summary.json", result.summary)
        return {
            "ok": True,
            "status": "complete",
            "artifact_files": ["summary.json"],
        }
    return {
        "ok": True,
        "status": result.status,
        "error_code": result.error_code,
    }


def main() -> int:
    raw = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(raw) > MAX_REQUEST_BYTES:
        return emit_error("request_too_large")
    try:
        request = json.loads(raw)
        if not isinstance(request, Mapping):
            raise SummaryError("request must be an object")
        response = execute_request(request)
    except (SummaryError, ProcessingError, OSError, ValueError):
        return emit_error("summary_request_failed")
    sys.stdout.write(json.dumps(response, ensure_ascii=False, separators=(",", ":")) + "\n")
    return 0


def emit_error(code: str) -> int:
    sys.stdout.write(json.dumps({"ok": False, "error_code": code}, separators=(",", ":")) + "\n")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
