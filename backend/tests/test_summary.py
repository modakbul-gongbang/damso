from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from damso.agent_boundary import BoundaryResult
from damso.summary import SummaryError, execute_request


COMPLETE_SUMMARY = {
    "title": "온보딩 워크숍 커리큘럼 논의",
    "role_hint": "facilitator",
    "topic_summary": "Synthetic topic",
    "one_line_summary": "Synthetic line",
    "key_points": ["One point"],
    "action_items": [{"task": "Follow up", "owner": None, "due": None}],
    "person_notes": [{"name": "Kim", "note": "Owns the launch checklist."}],
}


class _Boundary:
    def __init__(self, result: BoundaryResult) -> None:
        self.result = result
        self.calls: list[str] = []
        self.meeting_dates: list[str | None] = []

    def run_summary(self, transcript: object, *, language: str = "ko", meeting_date: str | None = None) -> BoundaryResult:
        self.calls.append(language)
        self.meeting_dates.append(meeting_date)
        return self.result


class SummaryTests(unittest.TestCase):
    def test_complete_summary_writes_only_bounded_canonical_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            record = self._record(Path(temporary))
            boundary = _Boundary(BoundaryResult("complete", COMPLETE_SUMMARY))
            captured = {}

            def factory(agent: str, root: Path):
                captured["agent"] = agent
                captured["root"] = root
                return boundary

            response = execute_request(
                {"recording_directory": str(record), "agent": "codex", "language": "en"},
                boundary_factory=factory,
            )

            self.assertEqual(response, {"ok": True, "status": "complete", "artifact_files": ["summary.json"]})
            self.assertEqual(captured["agent"], "codex")
            self.assertEqual(boundary.calls, ["en"])
            self.assertEqual(boundary.meeting_dates, [None])
            payload = json.loads((record / "summary.json").read_text(encoding="utf-8"))
            self.assertEqual(payload["one_line_summary"], "Synthetic line")
            self.assertEqual(payload["title"], COMPLETE_SUMMARY["title"])
            self.assertEqual(payload["person_notes"], COMPLETE_SUMMARY["person_notes"])
            self.assertFalse("segments" in response)

    def test_defaults_are_claude_and_korean(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            record = self._record(Path(temporary))
            boundary = _Boundary(BoundaryResult("complete", COMPLETE_SUMMARY))
            captured = {}

            def factory(agent: str, root: Path):
                captured["agent"] = agent
                return boundary

            execute_request({"recording_directory": str(record)}, boundary_factory=factory)
            self.assertEqual(captured["agent"], "claude")
            self.assertEqual(boundary.calls, ["ko"])

    def test_meeting_date_passes_through_and_malformed_dates_degrade_to_none(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            record = self._record(Path(temporary))
            boundary = _Boundary(BoundaryResult("complete", COMPLETE_SUMMARY))
            base = {"recording_directory": str(record), "agent": "codex", "language": "ko"}

            execute_request({**base, "meeting_date": "2026-07-16"}, boundary_factory=lambda agent, root: boundary)
            execute_request({**base, "meeting_date": "not a date"}, boundary_factory=lambda agent, root: boundary)

            self.assertEqual(boundary.meeting_dates, ["2026-07-16", None])

    def test_unknown_agent_or_language_is_rejected_before_cli_launch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            record = self._record(Path(temporary))
            with self.assertRaises(SummaryError):
                execute_request({"recording_directory": str(record), "agent": "gemini"}, boundary_factory=lambda *_: None)
            with self.assertRaises(SummaryError):
                execute_request({"recording_directory": str(record), "language": "fr"}, boundary_factory=lambda *_: None)

    def test_missing_agent_cli_is_a_bounded_failure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            record = self._record(Path(temporary))

            def factory(agent: str, root: Path):
                raise FileNotFoundError("codex CLI was not found")

            response = execute_request({"recording_directory": str(record), "agent": "codex"}, boundary_factory=factory)
            self.assertEqual(response, {"ok": True, "status": "failed", "error_code": "agent_cli_missing"})
            self.assertFalse((record / "summary.json").exists())

    def test_non_complete_boundary_result_never_writes_a_summary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            record = self._record(Path(temporary))
            boundary = _Boundary(BoundaryResult("failed", None, "timeout"))

            response = execute_request(
                {"recording_directory": str(record)},
                boundary_factory=lambda *_: boundary,
            )

            self.assertEqual(response, {"ok": True, "status": "failed", "error_code": "timeout"})
            self.assertFalse((record / "summary.json").exists())

    def test_rejects_a_record_without_a_local_transcript(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary) / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            with self.assertRaises(SummaryError):
                execute_request({"recording_directory": str(record)})

    @staticmethod
    def _record(root: Path) -> Path:
        record = root / "Plaud" / "recordings" / "fixture"
        record.mkdir(parents=True)
        (record / "transcript.json").write_text(
            json.dumps({"segments": [{"speaker": "SPEAKER_00", "text": "Synthetic local text"}]}),
            encoding="utf-8",
        )
        return record


if __name__ == "__main__":
    unittest.main()
