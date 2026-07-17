import json
import tempfile
import unittest
from pathlib import Path

from damso.contracts import ContractError, apply_resolutions, required_files_present, write_phase_one


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

    def test_invalid_resolution_never_overwrites_the_raw_transcript(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            raw = {"speakers": [], "segments": [], "duration": 0}
            (directory / "transcript.raw.json").write_text(json.dumps(raw), encoding="utf-8")
            with self.assertRaises(ContractError):
                apply_resolutions(directory, {"SPEAKER_00": {"action": "match"}})
            self.assertEqual(json.loads((directory / "transcript.raw.json").read_text(encoding="utf-8")), raw)
