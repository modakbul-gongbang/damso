import json
import tempfile
import unittest
from pathlib import Path

from damso.agent_boundary import BoundaryResult
from damso.speaker_hints import SpeakerHintsError, build_hints_prompt, execute_request, normalize_suggestions


VALID = {"suggestions": [
    {"speaker": "SPEAKER_01", "name": "험프리", "confidence": 0.4, "reason": "달리기 모임 언급"},
    {"speaker": "SPEAKER_00", "name": "김구름", "confidence": 0.8, "reason": "커리큘럼 담당으로 지칭됨"},
]}


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
        {"speaker": "SPEAKER_00", "text": "커리큘럼은 제가 정리할게요"},
        {"speaker": "SPEAKER_01", "text": "장제 쪽에서 같이 뛰었어요"},
    ]}, ensure_ascii=False), encoding="utf-8")
    peoples = root / "Plaud" / "peoples"
    for name in ["김구름", "험프리"]:
        d = peoples / name
        d.mkdir(parents=True)
        (d / "profile.md").write_text(f'---\nname: "{name}"\n---\n## Notes\n', encoding="utf-8")
    return record


class SpeakerHintsTests(unittest.TestCase):
    def test_normalize_sorts_by_confidence_and_rejects_extras(self):
        normalized = normalize_suggestions(VALID)
        self.assertEqual([s["name"] for s in normalized["suggestions"]], ["김구름", "험프리"])
        with self.assertRaises(ValueError):
            normalize_suggestions({"suggestions": [{**VALID["suggestions"][0], "extra": 1}]})
        with self.assertRaises(ValueError):
            normalize_suggestions({"suggestions": [{**VALID["suggestions"][0], "confidence": 1.4}]})

    def test_prompt_carries_known_people_and_untrusted_marker(self):
        prompt = build_hints_prompt({"segments": [{"speaker": "S", "text": "t"}]}, ["김구름", "험프리"], "ko")
        self.assertIn("KNOWN_PEOPLE", prompt)
        self.assertIn("김구름", prompt)
        self.assertIn("untrusted data", prompt)

    def test_execute_returns_only_speakers_present_in_transcript(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = make_record(Path(temporary))
            payload = {"suggestions": VALID["suggestions"] + [{"speaker": "SPEAKER_99", "name": "유령", "confidence": 0.9, "reason": "없음"}]}
            boundary = _Boundary(BoundaryResult("complete", normalize_suggestions(payload)))
            response = execute_request({"recording_directory": str(record)}, boundary_factory=lambda *_: boundary)
            self.assertEqual(response["status"], "complete")
            self.assertEqual({s["speaker"] for s in response["suggestions"]}, {"SPEAKER_00", "SPEAKER_01"})
            prompt = boundary.prompts[0][0]
            self.assertIn("김구름", prompt)
            self.assertIn("험프리", prompt)

    def test_missing_cli_and_unknown_agent_are_bounded(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = make_record(Path(temporary))
            def missing(agent, root):
                raise FileNotFoundError("no CLI")
            response = execute_request({"recording_directory": str(record)}, boundary_factory=missing)
            self.assertEqual(response, {"ok": True, "status": "failed", "error_code": "agent_cli_missing"})
            with self.assertRaises(SpeakerHintsError):
                execute_request({"recording_directory": str(record), "agent": "gemini"}, boundary_factory=lambda *_: None)


class RefreshCandidatesTests(unittest.TestCase):
    def test_refresh_recomputes_candidates_from_current_profiles(self):
        import numpy as np
        from damso.people import VOICE_EMBEDDING_MODEL, write_profile, write_voice_embedding
        from damso.processing import execute_request as processing_execute, write_speaker_embeddings

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = make_record(root)
            vector = np.zeros(8, dtype=np.float32); vector[0] = 1.0
            (record / "identification.json").write_text(json.dumps({
                "embedding_model": VOICE_EMBEDDING_MODEL,
                "proposals": {"SPEAKER_00": {"total_seconds": 1.0, "segment_count": 1, "excerpts": [], "candidates": []}},
                "version": 1,
            }), encoding="utf-8")
            write_speaker_embeddings(record, {"SPEAKER_00": vector.tolist()})
            match = root / "Plaud" / "peoples" / "김구름"
            write_profile(match / "profile.md", {"name": "김구름", "voice_model": VOICE_EMBEDDING_MODEL}, "## Notes\n")
            write_voice_embedding(match / "voice.npy", vector.tolist())

            response = processing_execute({
                "operation": "refresh-candidates",
                "recording_directory": str(record),
                "peoples_directory": str(root / "Plaud" / "peoples"),
            })

            self.assertTrue(response["ok"])
            identification = json.loads((record / "identification.json").read_text(encoding="utf-8"))
            candidates = identification["proposals"]["SPEAKER_00"]["candidates"]
            self.assertEqual(candidates[0]["name"], "김구름")
            self.assertGreater(candidates[0]["voice_score"], 0.9)


if __name__ == "__main__":
    unittest.main()
