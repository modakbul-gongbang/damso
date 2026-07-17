import json
import tempfile
import unittest
from pathlib import Path

from damso.agent_boundary import BoundaryResult
from damso.transcript_cleanup import (
    CLEANED_FILENAME,
    TranscriptCleanupError,
    build_cleanup_prompt,
    execute_request,
    make_corrections_normalizer,
)


class _Boundary:
    def __init__(self, result):
        self.result = result
        self.prompts = []

    def run_structured(self, prompt, schema, validate):
        self.prompts.append((prompt, schema))
        return self.result


def make_record(root: Path) -> Path:
    record = root / "Plaud" / "recordings" / "fixture"
    record.mkdir(parents=True)
    (record / "transcript.raw.json").write_text(json.dumps({"segments": [
        {"speaker": "SPEAKER_00", "text": "아 아 아 아 아 아 다시 이제 SF 쪽 이야기"},
        {"speaker": "SPEAKER_01", "text": "커리큘럼은 제가 정리할게요"},
    ]}, ensure_ascii=False), encoding="utf-8")
    return record


class CleanupNormalizerTests(unittest.TestCase):
    def test_accepts_only_shrinking_changes_and_drops_noops(self):
        normalize = make_corrections_normalizer(["아 아 아 아 아", "그대로인 문장"])
        result = normalize({"corrections": [
            {"index": 0, "text": "아 아 아"},
            {"index": 1, "text": "그대로인 문장"},
        ]})
        self.assertEqual(result, {"corrections": [{"index": 0, "text": "아 아 아"}]})

    def test_rejects_growth_out_of_range_and_duplicates(self):
        normalize = make_corrections_normalizer(["짧다"])
        with self.assertRaises(ValueError):
            normalize({"corrections": [{"index": 0, "text": "짧지 않게 늘어난 문장"}]})
        with self.assertRaises(ValueError):
            normalize({"corrections": [{"index": 5, "text": "x"}]})
        with self.assertRaises(ValueError):
            normalize({"corrections": [{"index": 0, "text": "짧"}, {"index": 0, "text": "다"}]})

    def test_allows_empty_replacement_for_pure_noise(self):
        normalize = make_corrections_normalizer(["뚜뚜뚜뚜"])
        result = normalize({"corrections": [{"index": 0, "text": ""}]})
        self.assertEqual(result["corrections"], [{"index": 0, "text": ""}])


class CleanupPromptTests(unittest.TestCase):
    def test_prompt_is_indexed_and_marks_untrusted_content(self):
        prompt = build_cleanup_prompt({"segments": [{"speaker": "A", "text": "hello"}]})
        self.assertIn("untrusted data", prompt)
        self.assertIn('"index": 0' .replace(" ", ""), prompt.replace(" ", ""))
        self.assertIn("Never rephrase", prompt)


class CleanupExecuteTests(unittest.TestCase):
    def test_complete_result_writes_overlay_and_keeps_original(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            record = make_record(root)
            original = (record / "transcript.raw.json").read_text(encoding="utf-8")
            boundary = _Boundary(BoundaryResult("complete", {"corrections": [{"index": 0, "text": "아 아 아 다시 이제 SF 쪽 이야기"}]}))

            response = execute_request(
                {"recording_directory": str(record), "agent": "claude"},
                boundary_factory=lambda agent, storage_root: boundary,
            )

            self.assertEqual(response["status"], "complete")
            self.assertEqual(response["correction_count"], 1)
            overlay = json.loads((record / CLEANED_FILENAME).read_text(encoding="utf-8"))
            self.assertEqual(overlay["corrections"][0]["index"], 0)
            self.assertEqual((record / "transcript.raw.json").read_text(encoding="utf-8"), original)

    def test_existing_overlay_is_reused_without_calling_the_agent(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            record = make_record(root)
            (record / CLEANED_FILENAME).write_text(json.dumps({"corrections": [{"index": 1, "text": "x"}]}), encoding="utf-8")
            boundary = _Boundary(BoundaryResult("complete", {"corrections": []}))

            response = execute_request(
                {"recording_directory": str(record), "agent": "claude"},
                boundary_factory=lambda agent, storage_root: boundary,
            )

            self.assertTrue(response["cached"])
            self.assertEqual(response["correction_count"], 1)
            self.assertEqual(boundary.prompts, [])

    def test_missing_cli_and_missing_transcript_are_bounded(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            record = make_record(root)

            def missing(agent, storage_root):
                raise FileNotFoundError

            response = execute_request({"recording_directory": str(record), "agent": "claude"}, boundary_factory=missing)
            self.assertEqual(response["error_code"], "agent_cli_missing")

            empty = root / "Plaud" / "recordings" / "empty"
            empty.mkdir(parents=True)
            with self.assertRaises(TranscriptCleanupError):
                execute_request({"recording_directory": str(empty), "agent": "claude"}, boundary_factory=lambda a, r: _Boundary(None))


if __name__ == "__main__":
    unittest.main()
