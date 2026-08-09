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


def make_record(root: Path, generation_id: str | None = None, name: str = "fixture") -> Path:
    record = root / "Plaud" / "recordings" / name
    record.mkdir(parents=True)
    transcript: dict = {"segments": [
        {"speaker": "SPEAKER_00", "text": "아 아 아 아 아 아 다시 이제 SF 쪽 이야기"},
        {"speaker": "SPEAKER_01", "text": "커리큘럼은 제가 정리할게요"},
    ]}
    if generation_id is not None:
        transcript["generation_id"] = generation_id
    (record / "transcript.raw.json").write_text(json.dumps(transcript, ensure_ascii=False), encoding="utf-8")
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

    def test_prompt_instructs_disfluency_removal_but_only_deletes(self):
        prompt = build_cleanup_prompt({"segments": [{"speaker": "A", "text": "hello"}]})
        # Aggressive policy: fillers, stutters, and false starts are cleaned.
        self.assertIn("fillers", prompt)
        self.assertIn("false starts", prompt)
        # But the pass may only delete words, never add or rewrite them.
        self.assertIn("ONLY delete words", prompt)

    def test_prompt_targets_non_speech_boilerplate_generically_without_phrase_list(self):
        prompt = build_cleanup_prompt({"segments": [{"speaker": "A", "text": "hello"}]})
        # The non-speech-hallucination rule is expressed by category and by
        # context, so it generalizes across recordings.
        self.assertIn("non-speech boilerplate", prompt)
        self.assertIn("from context", prompt)
        # Anti-overfitting guardrail: never enumerate the specific hallucinated
        # phrases seen in one recording.
        for overfit_phrase in ["다음 영상에서 만나요", "감사합니다", "좋아요", "구독"]:
            self.assertNotIn(overfit_phrase, prompt)


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

    def test_overlay_records_the_transcript_generation_id(self):
        with tempfile.TemporaryDirectory() as raw:
            record = make_record(Path(raw), generation_id="gen-A")
            boundary = _Boundary(BoundaryResult("complete", {"corrections": [{"index": 0, "text": "아 아 아 다시 이제 SF 쪽 이야기"}]}))

            execute_request(
                {"recording_directory": str(record), "agent": "claude"},
                boundary_factory=lambda agent, storage_root: boundary,
            )

            overlay = json.loads((record / CLEANED_FILENAME).read_text(encoding="utf-8"))
            self.assertEqual(overlay["generation_id"], "gen-A")

    def test_generation_mismatch_regenerates_instead_of_reusing_stale_overlay(self):
        with tempfile.TemporaryDirectory() as raw:
            # An overlay bound to an older generation (from before a recluster
            # rewrote the transcript) must not be reused against the current
            # transcript; the pass must run again and rebind the overlay.
            record = make_record(Path(raw), generation_id="gen-NEW")
            (record / CLEANED_FILENAME).write_text(
                json.dumps({"generation_id": "gen-OLD", "corrections": [{"index": 1, "text": "x"}]}),
                encoding="utf-8",
            )
            boundary = _Boundary(BoundaryResult("complete", {"corrections": [{"index": 0, "text": "아 아 아 다시 이제 SF 쪽 이야기"}]}))

            response = execute_request(
                {"recording_directory": str(record), "agent": "claude"},
                boundary_factory=lambda agent, storage_root: boundary,
            )

            self.assertNotIn("cached", response)
            self.assertEqual(len(boundary.prompts), 1)
            overlay = json.loads((record / CLEANED_FILENAME).read_text(encoding="utf-8"))
            self.assertEqual(overlay["generation_id"], "gen-NEW")
            self.assertEqual(overlay["corrections"][0]["index"], 0)

    def test_matching_generation_overlay_is_reused(self):
        with tempfile.TemporaryDirectory() as raw:
            record = make_record(Path(raw), generation_id="gen-SAME")
            (record / CLEANED_FILENAME).write_text(
                json.dumps({"generation_id": "gen-SAME", "corrections": [{"index": 1, "text": "x"}]}),
                encoding="utf-8",
            )
            boundary = _Boundary(BoundaryResult("complete", {"corrections": []}))

            response = execute_request(
                {"recording_directory": str(record), "agent": "claude"},
                boundary_factory=lambda agent, storage_root: boundary,
            )

            self.assertTrue(response["cached"])
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
