import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from damso.contracts import write_phase_one
from damso.people import read_profile
from damso.processing import (
    COMBINED_AUDIO_FILENAME,
    LocalProcessingPipeline,
    ProcessingError,
    canonical_audio_path,
    execute_request,
    legacy_system_audio_path,
)


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

    def test_stale_resolution_creates_neither_transcript_nor_people_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "Plaud" / "recordings" / "fixture"
            peoples = root / "Plaud" / "peoples"
            record.mkdir(parents=True)
            write_phase_one(
                record,
                None,
                {
                    "speakers": ["SPEAKER_00"],
                    "segments": [
                        {"speaker": "SPEAKER_00", "start": 0, "end": 1, "text": "synthetic"}
                    ],
                },
                {"proposals": {"SPEAKER_00": {"candidates": []}}},
            )

            result = self.run_cli(
                {
                    "operation": "apply-resolutions",
                    "recording_directory": str(record),
                    "peoples_directory": str(peoples),
                    "resolutions": {
                        "SPEAKER_17": {"action": "new", "name": "Stale Person"}
                    },
                }
            )

            self.assertEqual(result.returncode, 2)
            self.assertFalse(record.joinpath("transcript.json").exists())
            self.assertFalse(record.joinpath("resolutions.yaml").exists())
            self.assertFalse(peoples.exists())

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

    def test_phase_one_single_track_keeps_the_legacy_response_shape(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary) / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            microphone = record / "microphone.caf"
            microphone.write_bytes(b"synthetic")
            with patch.object(
                LocalProcessingPipeline,
                "run_phase_one",
                return_value={"speakers": ["SPEAKER_00"]},
            ) as run_phase_one:
                response = execute_request({
                    "operation": "phase-one",
                    "recording_directory": str(record),
                    "audio_path": str(microphone),
                    "hints": {},
                }, environment={})

            self.assertEqual(response["speaker_count"], 1)
            self.assertIsNone(response["processed_audio_file"])
            self.assertNotIn(COMBINED_AUDIO_FILENAME, response["artifact_files"])
            self.assertEqual(run_phase_one.call_args.kwargs["source_files"], [microphone.resolve()])

    def test_phase_one_rejects_secondary_audio_outside_record_symlink_or_missing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            microphone = record / "microphone.caf"
            microphone.write_bytes(b"synthetic")
            outside = root / "outside.m4a"
            outside.write_bytes(b"synthetic")
            base = {
                "operation": "phase-one",
                "recording_directory": str(record),
                "audio_path": str(microphone),
                "hints": {},
            }
            with self.assertRaisesRegex(ProcessingError, "system_audio_path"):
                execute_request({**base, "system_audio_path": str(outside)}, environment={})

            linked = record / "linked-system.m4a"
            linked.symlink_to(outside)
            with self.assertRaisesRegex(ProcessingError, "symbolic link"):
                execute_request({**base, "system_audio_path": str(linked)}, environment={})

            with self.assertRaisesRegex(ProcessingError, "existing local audio"):
                execute_request({**base, "system_audio_path": str(record / "missing.m4a")}, environment={})

    def test_primary_and_secondary_must_be_different_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary) / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            microphone = record / "microphone.caf"
            microphone.write_bytes(b"synthetic")
            request = {
                "operation": "phase-one",
                "recording_directory": str(record),
                "audio_path": str(microphone),
                "system_audio_path": str(microphone),
                "hints": {},
            }
            with self.assertRaisesRegex(ProcessingError, "second local audio source"):
                execute_request(request, environment={})

            hardlink = record / "same-audio.m4a"
            os.link(microphone, hardlink)
            with self.assertRaisesRegex(ProcessingError, "second local audio source"):
                execute_request({**request, "system_audio_path": str(hardlink)}, environment={})

    def test_corrupt_explicit_system_audio_has_a_recoverable_public_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary) / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            microphone = record / "microphone.wav"
            system = record / "system-audio.m4a"
            subprocess.run(
                [
                    "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
                    "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
                    str(microphone),
                ],
                check=True,
            )
            system.write_bytes(b"not audio")
            result = self.run_cli({
                "operation": "phase-one",
                "recording_directory": str(record),
                "audio_path": str(microphone),
                "system_audio_path": str(system),
                "hints": {},
            })

            self.assertEqual(result.returncode, 2)
            response = json.loads(result.stdout)
            self.assertEqual(response["error"]["code"], "captured_system_audio_unavailable")
            self.assertIn("Restore the captured system audio", response["error"]["next_action"])
            self.assertNotIn(str(record), result.stdout)

    def test_legacy_system_sibling_is_only_adopted_for_local_records(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary) / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            microphone = record / "microphone.caf"
            system = record / "system-audio.m4a"
            microphone.write_bytes(b"mic")
            system.write_bytes(b"system")
            record.joinpath("meeting.json").write_text(json.dumps({"source": "local"}), encoding="utf-8")
            canonical = canonical_audio_path(record, str(microphone))
            self.assertEqual(legacy_system_audio_path(record, canonical), system.resolve())

            record.joinpath("meeting.json").write_text(json.dumps({"source": "plaud"}), encoding="utf-8")
            self.assertIsNone(legacy_system_audio_path(record, canonical))
            record.joinpath("meeting.json").write_bytes(b"\xff\xfe\x00")
            self.assertIsNone(legacy_system_audio_path(record, canonical))

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


class ReclusterOperationTests(unittest.TestCase):
    def _record_with_transcript(self, root: Path) -> Path:
        record = root / "Plaud" / "recordings" / "fixture"
        record.mkdir(parents=True)
        (record / "microphone.caf").write_bytes(b"synthetic")
        (record / "transcript.raw.json").write_text(json.dumps({
            "segments": [
                {"start": 0, "end": 2, "text": "first", "speaker": "SPEAKER_00"},
                {"start": 2, "end": 4, "text": "second", "speaker": "SPEAKER_07"},
            ],
        }), encoding="utf-8")
        return record

    def test_requires_a_positive_integer_speaker_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = self._record_with_transcript(Path(temporary))
            base = {
                "operation": "recluster",
                "recording_directory": str(record),
                "audio_path": str(record / "microphone.caf"),
            }
            for bad in (None, 0, -1, 2.5, "2", True):
                with self.assertRaises(ProcessingError):
                    execute_request({**base, "num_speakers": bad}, environment={})

    def test_requires_an_existing_phase_one_transcript(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary) / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            (record / "microphone.caf").write_bytes(b"synthetic")
            with self.assertRaises(ProcessingError):
                execute_request({
                    "operation": "recluster",
                    "recording_directory": str(record),
                    "audio_path": str(record / "microphone.caf"),
                    "num_speakers": 2,
                }, environment={})

    def test_replays_the_stored_transcript_and_overrides_the_speaker_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = self._record_with_transcript(Path(temporary))
            (record / "hint.json").write_text(json.dumps({
                "participants": ["다예"],
                "topic": None,
                "domain_terms": [],
                "num_speakers": None,
            }), encoding="utf-8")
            with patch.object(
                LocalProcessingPipeline,
                "run_phase_one",
                return_value={"speakers": ["SPEAKER_00", "SPEAKER_01"]},
            ) as run_phase_one:
                response = execute_request({
                    "operation": "recluster",
                    "recording_directory": str(record),
                    "audio_path": str(record / "microphone.caf"),
                    "num_speakers": 2,
                }, environment={})

            self.assertEqual(response["stage"], "speaker_review")
            self.assertEqual(response["speaker_count"], 2)
            hints = run_phase_one.call_args.args[2]
            self.assertEqual(hints["num_speakers"], 2)
            self.assertEqual(hints["participants"], ["다예"])
