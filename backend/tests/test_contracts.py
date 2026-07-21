import json
import tempfile
import unittest
from pathlib import Path

from damso.contracts import ContractError, apply_resolutions, required_files_present, validate_transcript, write_phase_one


class ContractTests(unittest.TestCase):
    def test_phase_one_and_resolution_create_the_required_compatible_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_phase_one(
                directory,
                {"participants": ["Kim"], "topic": "Synthetic", "domain_terms": ["fixture"], "num_speakers": 1},
                {
                    "source_file": "audio.wav",
                    "language": "ko",
                    "model": "large-v3",
                    "duration": 4.0,
                    "speakers": ["SPEAKER_00"],
                    "segments": [{"speaker": "SPEAKER_00", "start": 0, "end": 4, "text": "synthetic text"}],
                },
                {"version": 1, "proposals": {"SPEAKER_00": {"candidates": []}}},
            )
            final = apply_resolutions(directory, {"SPEAKER_00": {"action": "new", "name": "Kim"}})

            self.assertEqual(final["segments"][0]["speaker"], "Kim")
            self.assertTrue(required_files_present(directory))
            self.assertIn("action: new", (directory / "resolutions.yaml").read_text(encoding="utf-8"))

    def test_name_only_resolution_labels_the_transcript_without_a_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_phase_one(
                directory,
                None,
                {
                    "source_file": "audio.wav",
                    "language": "ko",
                    "model": "large-v3",
                    "duration": 4.0,
                    "speakers": ["SPEAKER_00"],
                    "segments": [{"speaker": "SPEAKER_00", "start": 0, "end": 4, "text": "synthetic text"}],
                },
                {"version": 1, "proposals": {"SPEAKER_00": {"candidates": []}}},
            )
            final = apply_resolutions(directory, {"SPEAKER_00": {"action": "name_only", "name": "게스트"}})

            self.assertEqual(final["segments"][0]["speaker"], "게스트")
            self.assertIn("action: name_only", (directory / "resolutions.yaml").read_text(encoding="utf-8"))

    def test_invalid_resolution_never_overwrites_the_raw_transcript(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            raw = {"speakers": [], "segments": [], "duration": 0}
            (directory / "transcript.raw.json").write_text(json.dumps(raw), encoding="utf-8")
            with self.assertRaises(ContractError):
                apply_resolutions(directory, {"SPEAKER_00": {"action": "match"}})
            self.assertEqual(json.loads((directory / "transcript.raw.json").read_text(encoding="utf-8")), raw)

    def test_resolution_for_a_stale_speaker_writes_no_downstream_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_phase_one(
                directory,
                None,
                {
                    "speakers": ["SPEAKER_00"],
                    "segments": [
                        {"speaker": "SPEAKER_00", "start": 0, "end": 1, "text": "synthetic"}
                    ],
                },
                {"proposals": {"SPEAKER_00": {"candidates": []}}},
            )

            with self.assertRaisesRegex(ContractError, "current phase one transcript"):
                apply_resolutions(
                    directory,
                    {"SPEAKER_17": {"action": "new", "name": "Stale"}},
                )

            self.assertFalse(directory.joinpath("transcript.json").exists())
            self.assertFalse(directory.joinpath("resolutions.yaml").exists())

    def test_source_file_provenance_round_trips_without_changing_legacy_shape(self):
        legacy = validate_transcript({"speakers": [], "segments": []})
        self.assertNotIn("source_files", legacy)

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            write_phase_one(
                directory,
                None,
                {
                    "source_file": "combined-audio.m4a",
                    "source_files": ["microphone.caf", "system-audio.m4a", "microphone.caf"],
                    "speakers": ["SPEAKER_00"],
                    "segments": [{"speaker": "SPEAKER_00", "start": 0, "end": 1, "text": "synthetic"}],
                },
                {"proposals": {}},
            )
            raw = json.loads(directory.joinpath("transcript.raw.json").read_text(encoding="utf-8"))
            self.assertEqual(raw["source_files"], ["microphone.caf", "system-audio.m4a"])
            final = apply_resolutions(directory, {"SPEAKER_00": {"action": "name_only", "name": "Guest"}})
            self.assertEqual(final["source_files"], ["microphone.caf", "system-audio.m4a"])

    def test_source_file_provenance_rejects_paths(self):
        for unsafe in ["../outside.caf", "/tmp/outside.caf", "nested/audio.caf", "."]:
            with self.subTest(unsafe=unsafe), self.assertRaises(ContractError):
                validate_transcript({"source_files": [unsafe], "speakers": [], "segments": []})

    def test_phase_one_rejects_mismatched_generation_ids(self):
        with tempfile.TemporaryDirectory() as temporary, self.assertRaises(ContractError):
            write_phase_one(
                Path(temporary),
                None,
                {"generation_id": "new-run", "speakers": [], "segments": []},
                {"generation_id": "old-run", "proposals": {}},
            )
