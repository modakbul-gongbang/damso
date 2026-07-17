import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from damso.contracts import write_phase_one
from damso.people import read_profile
from damso.processing import ProcessingError, execute_request


class ProcessingCLITests(unittest.TestCase):
    def test_resolution_subprocess_writes_canonical_artifacts_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "Plaud" / "recordings" / "fixture"
            peoples = root / "Plaud" / "peoples"
            record.mkdir(parents=True)
            write_phase_one(
                record,
                {"participants": [], "domain_terms": []},
                {
                    "source_file": "microphone.caf",
                    "language": "ko",
                    "model": "synthetic",
                    "duration": 2,
                    "speakers": ["SPEAKER_00"],
                    "segments": [{"speaker": "SPEAKER_00", "start": 0, "end": 2, "text": "synthetic"}],
                },
                {"version": 1, "proposals": {"SPEAKER_00": {"candidates": []}}},
            )
            request = {
                "operation": "apply-resolutions",
                "recording_directory": str(record),
                "peoples_directory": str(peoples),
                "meeting_date": "2026-07-14",
                "resolutions": {"SPEAKER_00": {"action": "new", "name": "Kim"}},
            }

            first = self.run_cli(request)
            second = self.run_cli(request)

            self.assertEqual(first.returncode, 0, first.stderr)
            self.assertEqual(second.returncode, 0, second.stderr)
            response = json.loads(first.stdout)
            self.assertEqual(response["stage"], "ready_for_summary")
            self.assertEqual(response["recording_stem"], "fixture")
            self.assertNotIn(str(record), first.stdout)
            profile = peoples / "Kim" / "profile.md"
            fields, _ = read_profile(profile, "Kim", "2026-07-14")
            self.assertEqual(fields["meeting_count"], 1)
            self.assertEqual(fields["meeting_stems"], ["fixture"])
            self.assertEqual(json.loads(record.joinpath("transcript.json").read_text(encoding="utf-8"))["speakers"], ["Kim"])

    def test_phase_one_rejects_an_audio_path_outside_its_canonical_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            external_audio = root / "outside.caf"
            external_audio.write_bytes(b"synthetic")
            with self.assertRaises(ProcessingError):
                execute_request(
                    {
                        "operation": "phase-one",
                        "recording_directory": str(record),
                        "audio_path": str(external_audio),
                        "hints": {},
                    },
                    environment={},
                )

    def test_cli_error_is_actionable_without_leaking_the_requested_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            external = Path(temporary) / "not-a-record"
            external.mkdir()
            result = self.run_cli({"operation": "apply-resolutions", "recording_directory": str(external)})

            self.assertEqual(result.returncode, 2)
            self.assertNotIn(str(external), result.stdout)
            response = json.loads(result.stdout)
            self.assertEqual(response["error"]["code"], "invalid_local_processing_request")

    @staticmethod
    def run_cli(request: dict[str, object]) -> subprocess.CompletedProcess[str]:
        repository = Path(__file__).resolve().parents[2]
        environment = dict(os.environ)
        environment["PYTHONPATH"] = str(repository / "backend")
        return subprocess.run(
            [sys.executable, "-m", "damso.processing", "--request", "-"],
            input=json.dumps(request),
            text=True,
            capture_output=True,
            cwd=repository,
            env=environment,
            check=False,
        )
