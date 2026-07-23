import copy
import hashlib
import json
import math
import os
import signal
import struct
import subprocess
import sys
import tempfile
import unicodedata
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

from damso.people import VOICE_EMBEDDING_MODEL, apply_people_resolutions, read_profile
from damso.processing import (
    COMBINED_AUDIO_FILENAME,
    MAX_PROMPT_NAME_CHARS,
    MAX_PROMPT_NAMES,
    WHISPER_STYLE_CARRIER,
    LocalProcessingPipeline,
    MLXWhisperTranscriber,
    ProcessingError,
    ProcessingTerminated,
    SherpaDiarizer,
    assign_speakers,
    build_initial_prompt,
    captured_participant_names,
    combine_audio_sources,
    deferred_processing_termination_handlers,
    diarize_with_policy,
    execute_whisper_worker,
    isolate_request_process_group,
    known_people_names,
    merge_participant_hints,
    merge_tiny_speaker_fragments,
    name_variants,
    participant_retry_target,
    read_speaker_embeddings,
    run_owned_subprocess,
    select_prompt_names,
    terminate_whisper_worker,
    write_whisper_worker_segments,
)
from tests.live_recording_probe import (
    ProbeError,
    cleanup_aware_signal_handlers,
    real_sources,
    rms_windows,
    resolve_recording_directory,
    unexpected_error_code,
)


class FakeTranscriber:
    def transcribe(self, audio_path, hints):
        return [{"start": 0, "end": 2, "text": "first"}, {"start": 2.2, "end": 4, "text": "second"}, {"start": 5, "end": 6, "text": "third"}]


class FakeDiarizer:
    def diarize(self, audio_path, num_speakers):
        return [{"start": 0, "end": 4.2, "speaker": "SPEAKER_00"}, {"start": 4.5, "end": 6.5, "speaker": "SPEAKER_01"}]


class FakeDiarizerWithEmbeddings(FakeDiarizer):
    def speaker_embeddings(self, audio_path, intervals):
        return {"SPEAKER_00": [1.0, 0.0], "SPEAKER_01": [0.0, 1.0]}


class SequencedDiarizer:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []
        self.embedding_intervals = None

    def diarize(self, audio_path, num_speakers):
        self.calls.append(num_speakers)
        return copy.deepcopy(self.responses.pop(0))

    def speaker_embeddings(self, audio_path, intervals):
        self.embedding_intervals = intervals
        return {}


def speaker_intervals(count, seconds=10.0):
    return [
        {"start": index * seconds, "end": (index + 1) * seconds, "speaker": f"raw-{index}"}
        for index in range(count)
    ]


class ProcessingTests(unittest.TestCase):
    def test_request_process_becomes_its_own_process_group_leader(self):
        with patch("damso.processing.os.getpid", return_value=4321), patch(
            "damso.processing.os.getpgrp",
            return_value=1234,
        ), patch("damso.processing.os.setpgid") as set_process_group:
            isolate_request_process_group()

        set_process_group.assert_called_once_with(0, 0)

    def test_request_process_keeps_an_existing_private_process_group(self):
        with patch("damso.processing.os.getpid", return_value=4321), patch(
            "damso.processing.os.getpgrp",
            return_value=4321,
        ), patch("damso.processing.os.setpgid") as set_process_group:
            isolate_request_process_group()

        set_process_group.assert_not_called()

    def test_live_probe_adopts_canonical_system_audio_for_legacy_local_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            working = root / "working"
            source.mkdir()
            working.mkdir()
            source.joinpath("meeting.json").write_text(
                json.dumps(
                    {
                        "source": "local",
                        "originalAudioFile": "microphone.caf",
                        "systemAudioFile": None,
                    }
                ),
                encoding="utf-8",
            )
            source.joinpath("microphone.caf").write_bytes(b"microphone")
            source.joinpath("system-audio.m4a").write_bytes(b"system")

            microphone, system, original_hashes = real_sources(source, working, seconds=0)

            self.assertEqual(microphone.read_bytes(), b"microphone")
            self.assertEqual(system.read_bytes(), b"system")
            self.assertEqual(set(original_hashes), {"microphone.caf", "system-audio.m4a"})

    def test_live_probe_does_not_adopt_system_audio_for_nonlocal_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            working = root / "working"
            source.mkdir()
            working.mkdir()
            source.joinpath("meeting.json").write_text(
                json.dumps(
                    {
                        "source": "imported",
                        "originalAudioFile": "microphone.caf",
                        "systemAudioFile": None,
                    }
                ),
                encoding="utf-8",
            )
            source.joinpath("microphone.caf").write_bytes(b"microphone")
            source.joinpath("system-audio.m4a").write_bytes(b"system")

            with self.assertRaisesRegex(ProbeError, "recording_audio_metadata_invalid"):
                real_sources(source, working, seconds=0)

    def test_live_probe_unexpected_error_code_excludes_sensitive_message(self):
        try:
            raise RuntimeError("/private/recording/participant-name")
        except RuntimeError as error:
            code = unexpected_error_code(error)
        self.assertTrue(code.startswith("live_recording_probe_failed_RuntimeError_"))
        self.assertNotIn("private", code)
        self.assertNotIn("participant", code)

    def test_live_probe_resolves_home_variable_without_absolute_configuration(self):
        with tempfile.TemporaryDirectory() as temporary:
            expected = Path(temporary) / "recording"
            expected.mkdir()
            with patch.dict(os.environ, {"HOME": temporary}):
                resolved = resolve_recording_directory("$HOME/recording")
            self.assertEqual(resolved, expected.resolve())

    def test_local_phase_one_writes_provisional_contract_with_speaker_cards(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            record = root / "record"
            result = LocalProcessingPipeline(FakeTranscriber(), FakeDiarizer()).run_phase_one(record, audio, {"participants": ["Kim"], "num_speakers": 2})
            transcript = json.loads(record.joinpath("transcript.raw.json").read_text(encoding="utf-8"))
            identification = json.loads(record.joinpath("identification.json").read_text(encoding="utf-8"))
            completion = json.loads(record.joinpath("phase-one.complete.json").read_text(encoding="utf-8"))
            self.assertEqual(result["speakers"], ["SPEAKER_00", "SPEAKER_01"])
            self.assertEqual(len(identification["proposals"]["SPEAKER_00"]["excerpts"]), 1)
            self.assertEqual(transcript["generation_id"], identification["generation_id"])
            self.assertEqual(completion["generation_id"], transcript["generation_id"])
            self.assertTrue(record.joinpath("transcript.raw.json").is_file())
            self.assertTrue(record.joinpath("transcript.md").is_file())
            self.assertFalse(record.joinpath("phase-one.in-progress.json").exists())

    def test_assignment_uses_overlap_and_merges_adjacent_same_speaker(self):
        assigned = assign_speakers(
            [{"start": 0, "end": 1, "text": "one"}, {"start": 1.2, "end": 2, "text": "two"}, {"start": 3, "end": 4, "text": "three"}],
            [{"start": 0, "end": 2.1, "speaker": "A"}, {"start": 2.5, "end": 4.5, "speaker": "B"}],
        )
        self.assertEqual(assigned, [{"start": 0, "end": 2, "speaker": "A", "text": "one two"}, {"start": 3, "end": 4, "speaker": "B", "text": "three"}])

    def test_assignment_uses_nearest_diarized_speaker_for_timeline_gaps(self):
        assigned = assign_speakers(
            [
                {"start": 0, "end": 0.5, "text": "before"},
                {"start": 2.1, "end": 2.2, "text": "between"},
                {"start": 5, "end": 5.4, "text": "after"},
            ],
            [
                {"start": 0.8, "end": 2, "speaker": "A"},
                {"start": 2.4, "end": 4.7, "speaker": "B"},
            ],
        )
        self.assertEqual([segment["speaker"] for segment in assigned], ["A", "A", "B"])
        self.assertNotIn("UNKNOWN", {segment["speaker"] for segment in assigned})

    def test_confirmed_speaker_stores_a_provenance_marked_embedding_for_future_candidates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "Plaud" / "recordings" / "fixture"
            peoples = root / "Plaud" / "peoples"
            record.mkdir(parents=True)
            audio = record / "audio.caf"
            audio.write_bytes(b"synthetic")
            pipeline = LocalProcessingPipeline(FakeTranscriber(), FakeDiarizerWithEmbeddings())
            pipeline.run_phase_one(record, audio, {})
            model, embeddings = read_speaker_embeddings(record)
            self.assertEqual(model, VOICE_EMBEDDING_MODEL)
            self.assertEqual(set(embeddings), {"SPEAKER_00", "SPEAKER_01"})

            from damso.contracts import apply_resolutions

            apply_resolutions(record, {"SPEAKER_00": {"action": "new", "name": "Synthetic Person"}})
            apply_people_resolutions(
                peoples,
                {"SPEAKER_00": {"action": "new", "name": "Synthetic Person"}},
                speaker_embeddings=embeddings,
                speaker_embedding_model=model,
            )
            profile = peoples / "Synthetic-Person" / "profile.md"
            fields, _ = read_profile(profile, "Synthetic Person", "2026-07-15")
            self.assertEqual(fields["voice_model"], VOICE_EMBEDDING_MODEL)
            self.assertTrue((profile.parent / "voice.npy").is_file())

            next_record = root / "Plaud" / "recordings" / "next"
            next_record.mkdir(parents=True)
            next_audio = next_record / "audio.caf"
            next_audio.write_bytes(b"synthetic")
            LocalProcessingPipeline(FakeTranscriber(), FakeDiarizerWithEmbeddings()).run_phase_one(next_record, next_audio, {})
            proposals = json.loads((next_record / "identification.json").read_text(encoding="utf-8"))["proposals"]
            self.assertEqual(proposals["SPEAKER_00"]["candidates"][0]["name"], "Synthetic Person")

    def test_captured_participants_merge_stably_and_malformed_files_degrade(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary)
            record.joinpath("participants.json").write_text(
                json.dumps({"participants": [{"name": " kim "}, {"name": "Captured"}, {"name": 4}, None]}),
                encoding="utf-8",
            )
            captured = captured_participant_names(record)
            self.assertEqual(captured, ["kim", "Captured"])
            merged = merge_participant_hints({"participants": ["Manual", "Kim"], "domain_terms": []}, captured)
            self.assertEqual(merged["participants"], ["Manual", "Kim", "Captured"])

            record.joinpath("participants.json").write_text("{broken", encoding="utf-8")
            self.assertEqual(captured_participant_names(record), [])
            record.joinpath("participants.json").write_bytes(b"\xff\xfe\x00")
            self.assertEqual(captured_participant_names(record), [])
            record.joinpath("participants.json").write_text(json.dumps({"participants": "wrong"}), encoding="utf-8")
            self.assertEqual(captured_participant_names(record), [])

    def test_pipeline_persists_captured_participants_in_effective_hint(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            record.joinpath("participants.json").write_text(
                json.dumps({"participants": [{"name": "Kim"}, {"name": "Captured"}]}),
                encoding="utf-8",
            )
            audio = record / "audio.caf"
            audio.write_bytes(b"synthetic")
            LocalProcessingPipeline(FakeTranscriber(), FakeDiarizer()).run_phase_one(
                record,
                audio,
                {"participants": ["Manual", "kim"], "domain_terms": []},
            )
            hint = json.loads(record.joinpath("hint.json").read_text(encoding="utf-8"))
            self.assertEqual(hint["participants"], ["Manual", "kim", "Captured"])

    def test_explicit_speaker_counts_one_and_two_are_authoritative_and_called_once(self):
        cases = {
            1: [{"start": 0, "end": 101, "speaker": "dominant"}],
            2: [
                {"start": 0, "end": 100, "speaker": "dominant"},
                {"start": 100, "end": 101, "speaker": "tiny"},
            ],
        }
        for explicit_count, raw in cases.items():
            with self.subTest(explicit_count=explicit_count):
                diarizer = SequencedDiarizer([raw])
                result = diarize_with_policy(diarizer, Path("unused"), explicit_count, participant_count=8)
                self.assertEqual(diarizer.calls, [explicit_count])
                self.assertEqual(len({item["speaker"] for item in result}), explicit_count)

    def test_fragment_cleanup_is_deterministic_contiguous_and_non_mutating(self):
        raw = [
            {"start": 0, "end": 88, "speaker": "main"},
            {"start": 88, "end": 89, "speaker": "noise"},
            {"start": 89, "end": 90, "speaker": "noise"},
            {"start": 90, "end": 179, "speaker": "main"},
        ]
        original = copy.deepcopy(raw)
        first = merge_tiny_speaker_fragments(raw)
        second = merge_tiny_speaker_fragments(raw)
        self.assertEqual(raw, original)
        self.assertEqual(first, second)
        self.assertEqual({item["speaker"] for item in first}, {"SPEAKER_00"})

    def test_fragment_cleanup_merges_by_total_duration_regardless_of_turn_length(self):
        # Total duration decides merging, not any single turn's length: real
        # conversational audio has plenty of over-split speakers whose turns
        # run well past a few seconds, and a turn-length gate left most of
        # them uncorrected (a real 49-speaker, 2-person recording only had 8
        # speakers whose longest turn was <=3s).
        merged = merge_tiny_speaker_fragments(
            [
                {"start": 0, "end": 50, "speaker": "A"},
                {"start": 50, "end": 55, "speaker": "B"},  # a single 5s turn
                {"start": 55, "end": 105, "speaker": "A"},
            ]
        )
        self.assertEqual({item["speaker"] for item in merged}, {"SPEAKER_00"})

    def test_fragment_cleanup_preserves_a_minor_speaker_whose_total_clears_the_cap(self):
        preserved = merge_tiny_speaker_fragments(
            [
                {"start": 0, "end": 1000, "speaker": "A"},
                {"start": 1000, "end": 1070, "speaker": "B"},  # 70s total, above the 60s cap
                {"start": 1070, "end": 2000, "speaker": "A"},
            ]
        )
        self.assertEqual(len({item["speaker"] for item in preserved}), 2)

    def test_fragment_cleanup_preserves_ambiguous_votes(self):
        ambiguous = merge_tiny_speaker_fragments(
            [
                {"start": 0, "end": 50, "speaker": "A"},
                {"start": 50, "end": 51, "speaker": "noise"},
                {"start": 51, "end": 101, "speaker": "B"},
            ]
        )
        self.assertEqual(len({item["speaker"] for item in ambiguous}), 3)

    def test_fragment_cleanup_keeps_all_candidate_input_when_no_target_exists(self):
        raw = [
            {"start": float(index), "end": float(index + 1), "speaker": f"label-{index}"}
            for index in range(21)
        ]
        cleaned = merge_tiny_speaker_fragments(raw)
        self.assertEqual(len({item["speaker"] for item in cleaned}), 21)

    def test_participant_retry_policy_only_constrains_observed_explosions(self):
        self.assertEqual(participant_retry_target(3, 2), 2)
        self.assertIsNone(participant_retry_target(1, 2))
        self.assertIsNone(participant_retry_target(2, 5))
        self.assertIsNone(participant_retry_target(9, 5))
        self.assertEqual(participant_retry_target(10, 5), 5)

        diarizer = SequencedDiarizer([speaker_intervals(3), speaker_intervals(2)])
        result = diarize_with_policy(diarizer, Path("unused"), None, participant_count=2)
        self.assertEqual(diarizer.calls, [None, 2])
        self.assertEqual(len({item["speaker"] for item in result}), 2)

        no_retry = SequencedDiarizer([speaker_intervals(1)])
        diarize_with_policy(no_retry, Path("unused"), None, participant_count=2)
        self.assertEqual(no_retry.calls, [None])

        invalid_candidate = SequencedDiarizer([speaker_intervals(3), speaker_intervals(4)])
        preserved = diarize_with_policy(invalid_candidate, Path("unused"), None, participant_count=2)
        self.assertEqual(invalid_candidate.calls, [None, 2])
        self.assertEqual(len({item["speaker"] for item in preserved}), 3)

    def test_pipeline_uses_the_same_cleaned_intervals_for_assignment_and_embeddings(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            audio = record / "audio.caf"
            audio.write_bytes(b"synthetic")
            diarizer = SequencedDiarizer([
                [
                    {"start": 0, "end": 4, "speaker": "A"},
                    {"start": 4, "end": 5, "speaker": "noise"},
                    {"start": 5, "end": 100, "speaker": "A"},
                ]
            ])
            assignment_intervals = []

            def recording_assign(segments, intervals):
                assignment_intervals.append(intervals)
                return assign_speakers(segments, intervals)

            with patch("damso.processing.assign_speakers", side_effect=recording_assign):
                LocalProcessingPipeline(FakeTranscriber(), diarizer).run_phase_one(record, audio, {})
            self.assertIs(assignment_intervals[0], diarizer.embedding_intervals)

    def test_pipeline_finishes_isolated_whisper_before_sherpa_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            audio = record / "audio.caf"
            audio.write_bytes(b"synthetic")
            events = []

            class OrderedTranscriber(FakeTranscriber):
                def transcribe(self, audio_path, hints):
                    events.append("transcribe")
                    return super().transcribe(audio_path, hints)

            class OrderedDiarizer(FakeDiarizerWithEmbeddings):
                def diarize(self, audio_path, num_speakers):
                    events.append("diarize")
                    return super().diarize(audio_path, num_speakers)

                def speaker_embeddings(self, audio_path, intervals):
                    events.append("embeddings")
                    return super().speaker_embeddings(audio_path, intervals)

            LocalProcessingPipeline(OrderedTranscriber(), OrderedDiarizer()).run_phase_one(record, audio, {})
            self.assertEqual(events, ["transcribe", "diarize", "embeddings"])

    def test_pipeline_completes_isolated_whisper_before_sherpa_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            audio = record / "audio.caf"
            audio.write_bytes(b"synthetic")
            events = []

            class TrackingTranscriber(FakeTranscriber):
                def transcribe(self, audio_path, hints):
                    events.append("transcribe")
                    return super().transcribe(audio_path, hints)

            class FailingDiarizer(FakeDiarizer):
                def diarize(self, audio_path, num_speakers):
                    events.append("diarize")
                    raise RuntimeError("synthetic diarizer failure")

            with self.assertRaisesRegex(RuntimeError, "synthetic diarizer failure"):
                LocalProcessingPipeline(TrackingTranscriber(), FailingDiarizer()).run_phase_one(record, audio, {})
            self.assertEqual(events, ["transcribe", "diarize"])

    def test_mlx_transcriber_uses_an_unlinked_fd_without_transcript_stdout(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            model = root / "model"
            model.mkdir()
            observed = {}

            class FakeConfig:
                mlx_whisper_model_directory = model

                @staticmethod
                def validate():
                    return None

            class FakeProcess:
                returncode = 0

                def __init__(self, arguments, **options):
                    observed["arguments"] = arguments
                    observed["options"] = options

                def communicate(self, payload):
                    request = json.loads(payload)
                    observed["request"] = request
                    observed["output_nlink"] = os.fstat(request["output_fd"]).st_nlink
                    observed["output_inheritable"] = os.get_inheritable(request["output_fd"])
                    os.write(
                        request["output_fd"],
                        json.dumps([{"start": 0, "end": 1, "text": " hello "}]).encode("utf-8"),
                    )

            with patch("damso.processing.subprocess.Popen", side_effect=FakeProcess):
                segments = MLXWhisperTranscriber(FakeConfig()).transcribe(
                    audio,
                    {"topic": "private topic", "domain_terms": ["private term"]},
                )

            self.assertEqual(segments, [{"start": 0.0, "end": 1.0, "text": "hello"}])
            self.assertEqual(
                observed["arguments"],
                [sys.executable, "-m", "damso.processing", "--whisper-worker", "-"],
            )
            self.assertIs(observed["options"]["stdout"], subprocess.DEVNULL)
            self.assertIs(observed["options"]["stderr"], subprocess.DEVNULL)
            self.assertTrue(observed["options"]["close_fds"])
            self.assertEqual(observed["options"]["pass_fds"], (observed["request"]["output_fd"],))
            self.assertEqual(observed["output_nlink"], 0)
            self.assertFalse(observed["output_inheritable"])
            self.assertNotIn("output_directory", observed["request"])
            self.assertNotIn(str(audio), " ".join(observed["arguments"]))

    def test_mlx_transcriber_forwards_sigterm_to_its_worker_before_unwinding(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            model = root / "model"
            model.mkdir()

            class FakeConfig:
                mlx_whisper_model_directory = model

                @staticmethod
                def validate():
                    return None

            class InterruptedProcess:
                returncode = None
                terminated = False

                def communicate(self, payload):
                    os.kill(os.getpid(), signal.SIGTERM)

                def poll(self):
                    return self.returncode

                def terminate(self):
                    self.terminated = True

                def wait(self, timeout=None):
                    self.returncode = -15
                    return self.returncode

            process = InterruptedProcess()
            with patch("damso.processing.subprocess.Popen", return_value=process):
                with self.assertRaisesRegex(ProcessingTerminated, "terminated"):
                    MLXWhisperTranscriber(FakeConfig()).transcribe(audio, {})
            self.assertTrue(process.terminated)

    def test_mlx_transcriber_cleans_worker_when_sigterm_arrives_during_popen_return(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            model = root / "model"
            model.mkdir()
            observed = {}

            class FakeConfig:
                mlx_whisper_model_directory = model

                @staticmethod
                def validate():
                    return None

            class ConstructorInterruptedProcess:
                returncode = None
                terminated = False

                def __init__(self, *_arguments, **_options):
                    observed["process"] = self
                    os.kill(os.getpid(), signal.SIGTERM)

                def communicate(self, _payload):
                    raise AssertionError("pending termination must fire before communicate")

                def poll(self):
                    return self.returncode

                def terminate(self):
                    self.terminated = True

                def wait(self, timeout=None):
                    self.returncode = -signal.SIGTERM
                    return self.returncode

            with patch("damso.processing.subprocess.Popen", side_effect=ConstructorInterruptedProcess):
                with self.assertRaisesRegex(ProcessingTerminated, "terminated"):
                    MLXWhisperTranscriber(FakeConfig()).transcribe(audio, {})
            self.assertTrue(observed["process"].terminated)

    def test_repeated_sigterm_force_kills_the_worker_instead_of_being_swallowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            model = root / "model"
            model.mkdir()

            class FakeConfig:
                mlx_whisper_model_directory = model

                @staticmethod
                def validate():
                    return None

            class RepeatedlyInterruptedProcess:
                returncode = None
                terminated = False
                killed = False

                def communicate(self, _payload):
                    os.kill(os.getpid(), signal.SIGTERM)

                def poll(self):
                    return self.returncode

                def terminate(self):
                    self.terminated = True
                    os.kill(os.getpid(), signal.SIGTERM)

                def kill(self):
                    self.killed = True
                    self.returncode = -signal.SIGKILL

                def wait(self, timeout=None):
                    return self.returncode

            process = RepeatedlyInterruptedProcess()
            with patch("damso.processing.subprocess.Popen", return_value=process):
                with self.assertRaisesRegex(ProcessingTerminated, "again"):
                    MLXWhisperTranscriber(FakeConfig()).transcribe(audio, {})
            self.assertTrue(process.terminated)
            self.assertTrue(process.killed)

    def test_repeated_pre_arm_sigterm_forces_stop_and_is_not_swallowed(self):
        force_stops = []

        with self.assertRaisesRegex(ProcessingTerminated, "again"):
            with deferred_processing_termination_handlers(lambda: force_stops.append("forced")):
                os.kill(os.getpid(), signal.SIGTERM)
                os.kill(os.getpid(), signal.SIGTERM)

        self.assertEqual(force_stops, ["forced"])

    def test_owned_subprocess_repeated_sigterm_force_kills_and_reaps_child(self):
        class RepeatedlyInterruptedProcess:
            returncode = None
            terminated = False
            killed = False
            waits = []

            def communicate(self):
                os.kill(os.getpid(), signal.SIGTERM)
                raise AssertionError("signal handler must interrupt communicate")

            def poll(self):
                return self.returncode

            def terminate(self):
                self.terminated = True
                os.kill(os.getpid(), signal.SIGTERM)

            def kill(self):
                self.killed = True
                self.returncode = -signal.SIGKILL

            def wait(self, timeout=None):
                self.waits.append(timeout)
                return self.returncode

        process = RepeatedlyInterruptedProcess()
        with patch("damso.processing.subprocess.Popen", return_value=process):
            with self.assertRaisesRegex(ProcessingTerminated, "again"):
                run_owned_subprocess(["synthetic-child"], check=True, capture_output=True, text=True)

        self.assertTrue(process.terminated)
        self.assertTrue(process.killed)
        self.assertEqual(process.waits, [None])

    def test_whisper_worker_termination_escalates_after_the_grace_period(self):
        class StubbornProcess:
            terminated = False
            killed = False
            waits = []

            @staticmethod
            def poll():
                return None

            def terminate(self):
                self.terminated = True

            def wait(self, timeout=None):
                self.waits.append(timeout)
                if timeout is not None:
                    raise subprocess.TimeoutExpired(["synthetic-worker"], timeout)
                return -signal.SIGKILL

            def kill(self):
                self.killed = True

        process = StubbornProcess()
        terminate_whisper_worker(process)
        self.assertTrue(process.terminated)
        self.assertTrue(process.killed)
        self.assertEqual(process.waits, [5.0, None])

    def test_whisper_worker_writes_only_to_a_new_unlinked_regular_fd(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            model = root / "model"
            model.mkdir()
            expected = [{"start": 0.0, "end": 1.0, "text": "hello"}]
            with tempfile.TemporaryFile(mode="w+b") as output:
                output_descriptor = output.fileno()
                os.set_inheritable(output_descriptor, True)
                request = {
                    "audio_path": str(audio),
                    "model_directory": str(model),
                    "initial_prompt": None,
                    "output_fd": output_descriptor,
                }
                with patch("damso.processing.mlx_whisper_segments", return_value=expected):
                    execute_whisper_worker(request)
                self.assertEqual(os.fstat(output_descriptor).st_nlink, 0)
                self.assertFalse(os.get_inheritable(output_descriptor))
                output.seek(0)
                self.assertEqual(json.load(output), expected)

    def test_whisper_worker_streaming_write_rejects_oversize_and_clears_partial_output(self):
        with tempfile.TemporaryFile(mode="w+b") as output, patch(
            "damso.processing.MAX_WHISPER_WORKER_OUTPUT_BYTES",
            64,
        ):
            with self.assertRaisesRegex(ProcessingError, "too large"):
                write_whisper_worker_segments(
                    output.fileno(),
                    [{"start": 0.0, "end": 1.0, "text": "x" * 256}],
                )

            output.seek(0)
            self.assertEqual(output.read(), b"")

    def test_mlx_transcriber_rejects_oversize_worker_output_at_the_parent_read_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            model = root / "model"
            model.mkdir()

            class FakeConfig:
                mlx_whisper_model_directory = model

                @staticmethod
                def validate():
                    return None

            class OversizedOutputProcess:
                returncode = 0

                @staticmethod
                def communicate(payload):
                    request = json.loads(payload)
                    os.write(request["output_fd"], b"x" * 65)

            with patch("damso.processing.MAX_WHISPER_WORKER_OUTPUT_BYTES", 64), patch(
                "damso.processing.subprocess.Popen",
                return_value=OversizedOutputProcess(),
            ):
                with self.assertRaisesRegex(ProcessingError, "too large"):
                    MLXWhisperTranscriber(FakeConfig()).transcribe(audio, {})

    def test_whisper_worker_cli_inherits_the_anonymous_fd_only(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            model = root / "model"
            model.mkdir()
            stub_modules = root / "stub-modules"
            stub_modules.mkdir()
            stub_modules.joinpath("mlx_whisper.py").write_text(
                "def transcribe(*args, **kwargs):\n"
                "    return {'segments': [{'start': 0, 'end': 1, 'text': 'hello'}]}\n",
                encoding="utf-8",
            )
            environment = dict(os.environ)
            python_paths = [str(stub_modules), str(Path(__file__).resolve().parents[1])]
            if environment.get("PYTHONPATH"):
                python_paths.append(environment["PYTHONPATH"])
            environment["PYTHONPATH"] = os.pathsep.join(python_paths)

            with tempfile.TemporaryFile(mode="w+b") as output:
                output_descriptor = output.fileno()
                request = {
                    "audio_path": str(audio),
                    "model_directory": str(model),
                    "initial_prompt": None,
                    "output_fd": output_descriptor,
                }
                completed = subprocess.run(
                    [sys.executable, "-m", "damso.processing", "--whisper-worker", "-"],
                    input=json.dumps(request),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    close_fds=True,
                    pass_fds=(output_descriptor,),
                    env=environment,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(os.fstat(output_descriptor).st_nlink, 0)
                self.assertFalse(os.get_inheritable(output_descriptor))
                output.seek(0)
                self.assertEqual(json.load(output), [{"start": 0.0, "end": 1.0, "text": "hello"}])

    def test_whisper_worker_rejects_linked_prefilled_and_nonregular_descriptors(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            model = root / "model"
            model.mkdir()
            request = {
                "audio_path": str(audio),
                "model_directory": str(model),
                "initial_prompt": None,
            }

            with tempfile.NamedTemporaryFile() as linked:
                request["output_fd"] = linked.fileno()
                with self.assertRaisesRegex(ProcessingError, "output descriptor"):
                    execute_whisper_worker(request)

            with tempfile.TemporaryFile(mode="w+b") as prefilled:
                prefilled.write(b"private")
                prefilled.flush()
                request["output_fd"] = prefilled.fileno()
                with self.assertRaisesRegex(ProcessingError, "output descriptor"):
                    execute_whisper_worker(request)

            read_descriptor, write_descriptor = os.pipe()
            try:
                request["output_fd"] = write_descriptor
                with self.assertRaisesRegex(ProcessingError, "output descriptor"):
                    execute_whisper_worker(request)
            finally:
                os.close(read_descriptor)
                os.close(write_descriptor)


class AudioCombinationTests(unittest.TestCase):
    @staticmethod
    def write_tone(path, active_start, active_end, frequency, duration=2.0, sample_rate=16_000):
        frames = []
        for index in range(int(duration * sample_rate)):
            seconds = index / sample_rate
            value = 0.35 * math.sin(2 * math.pi * frequency * seconds) if active_start <= seconds < active_end else 0.0
            frames.append(struct.pack("<h", int(value * 32767)))
        with wave.open(str(path), "wb") as output:
            output.setnchannels(1)
            output.setsampwidth(2)
            output.setframerate(sample_rate)
            output.writeframes(b"".join(frames))

    @staticmethod
    def sha256(path):
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def test_combination_preserves_both_raw_sources_and_activity_windows(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary)
            microphone = record / "microphone.wav"
            system = record / "system.wav"
            self.write_tone(microphone, 0.1, 0.8, 440)
            self.write_tone(system, 1.2, 1.9, 880)
            before = [self.sha256(microphone), self.sha256(system)]

            combined = combine_audio_sources(record, microphone, system)

            self.assertEqual(combined.name, COMBINED_AUDIO_FILENAME)
            self.assertGreater(combined.stat().st_size, 0)
            self.assertEqual(before, [self.sha256(microphone), self.sha256(system)])
            decoded = record / "decoded.wav"
            subprocess.run(
                ["ffmpeg", "-y", "-hide_banner", "-loglevel", "error", "-i", str(combined), "-ac", "1", "-ar", "16000", str(decoded)],
                check=True,
            )
            with wave.open(str(decoded), "rb") as audio:
                samples = struct.unpack(f"<{audio.getnframes()}h", audio.readframes(audio.getnframes()))
            first = samples[int(0.2 * 16000):int(0.7 * 16000)]
            second = samples[int(1.3 * 16000):int(1.8 * 16000)]
            self.assertGreater(sum(abs(value) for value in first) / len(first), 1000)
            self.assertGreater(sum(abs(value) for value in second) / len(second), 1000)

    def test_combination_never_replaces_a_raw_source_named_as_the_derivative(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary)
            raw_source = record / COMBINED_AUDIO_FILENAME
            system = record / "system.wav"
            raw_source.write_bytes(b"original microphone bytes")
            system.write_bytes(b"original system bytes")
            before = [self.sha256(raw_source), self.sha256(system)]

            with self.assertRaisesRegex(ProcessingError, "must not replace a raw audio source"):
                combine_audio_sources(record, raw_source, system)

            self.assertEqual(before, [self.sha256(raw_source), self.sha256(system)])

    def test_failed_combination_keeps_previous_good_derivative_and_cleans_temporary_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary)
            microphone = record / "microphone.wav"
            system = record / "system.m4a"
            self.write_tone(microphone, 0, 1, 440, duration=1)
            system.write_bytes(b"not audio")
            destination = record / COMBINED_AUDIO_FILENAME
            destination.write_bytes(b"known-good")

            with self.assertRaises(ProcessingError):
                combine_audio_sources(record, microphone, system)

            self.assertEqual(destination.read_bytes(), b"known-good")
            self.assertEqual(list(record.glob(".combined-audio-*")), [])

    def test_late_system_decode_failure_remains_source_specific_and_recoverable(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary)
            microphone = record / "microphone.wav"
            system = record / "system.m4a"
            microphone.write_bytes(b"valid prefix")
            system.write_bytes(b"valid prefix with late corruption")
            destination = record / COMBINED_AUDIO_FILENAME
            destination.write_bytes(b"known-good")
            success = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
            mix_failure = subprocess.CalledProcessError(1, ["ffmpeg"])
            system_failure = subprocess.CalledProcessError(1, ["ffmpeg"])

            with patch(
                "damso.processing.run_owned_subprocess",
                side_effect=[success, success, mix_failure, success, system_failure],
            ):
                with self.assertRaisesRegex(ProcessingError, "system_audio_path"):
                    combine_audio_sources(record, microphone, system)

            self.assertEqual(destination.read_bytes(), b"known-good")
            self.assertEqual(list(record.glob(".combined-audio-*")), [])

    def test_sigterm_after_combined_temp_creation_unwinds_and_removes_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary)
            microphone = record / "microphone.wav"
            system = record / "system.wav"
            microphone.write_bytes(b"synthetic microphone")
            system.write_bytes(b"synthetic system")

            def interrupt_before_spawn(_command, **_options):
                self.assertEqual(len(list(record.glob(".combined-audio-*"))), 1)
                os.kill(os.getpid(), signal.SIGTERM)

            with patch("damso.processing.validate_decodable_audio"), patch(
                "damso.processing.run_owned_subprocess",
                side_effect=interrupt_before_spawn,
            ):
                with self.assertRaisesRegex(ProcessingTerminated, "terminated"):
                    combine_audio_sources(record, microphone, system)

            self.assertEqual(list(record.glob(".combined-audio-*")), [])


class SherpaWaveformLifecycleTests(unittest.TestCase):
    def test_sigterm_after_pcm_temp_creation_unwinds_and_removes_directory(self):
        observed = {}

        def interrupt_before_spawn(command, **_options):
            wav_path = Path(command[-1])
            observed["wav_path"] = wav_path
            self.assertTrue(wav_path.parent.is_dir())
            os.kill(os.getpid(), signal.SIGTERM)

        with patch("damso.processing.shutil.which", return_value="/usr/bin/ffmpeg"), patch(
            "damso.processing.run_owned_subprocess",
            side_effect=interrupt_before_spawn,
        ):
            with self.assertRaisesRegex(ProcessingTerminated, "terminated"):
                SherpaDiarizer(config=None).waveform(Path("synthetic-audio"))

        self.assertFalse(observed["wav_path"].parent.exists())


class LiveProbeSafetyTests(unittest.TestCase):
    def test_sigterm_during_energy_read_escalates_and_reaps_ffmpeg(self):
        class InterruptingStdout:
            closed = False

            def read(self, _size):
                os.kill(os.getpid(), signal.SIGTERM)

            def close(self):
                self.closed = True

        class StubbornProcess:
            returncode = None
            terminated = False
            killed = False
            waits = []
            stdout = InterruptingStdout()

            def poll(self):
                return self.returncode

            def terminate(self):
                self.terminated = True

            def wait(self, timeout=None):
                self.waits.append(timeout)
                if timeout is not None:
                    raise subprocess.TimeoutExpired(["synthetic-ffmpeg"], timeout)
                self.returncode = -signal.SIGKILL
                return self.returncode

            def kill(self):
                self.killed = True

        process = StubbornProcess()
        with patch("tests.live_recording_probe.subprocess.Popen", return_value=process):
            with self.assertRaisesRegex(ProbeError, "probe_terminated"):
                with cleanup_aware_signal_handlers():
                    rms_windows(Path("unused"))

        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.terminated)
        self.assertTrue(process.killed)
        self.assertEqual(process.waits, [5.0, None])

    def test_energy_read_exception_terminates_and_reaps_ffmpeg_without_escalation(self):
        class FailingStdout:
            closed = False

            def read(self, _size):
                raise RuntimeError("synthetic read failure")

            def close(self):
                self.closed = True

        class CooperativeProcess:
            returncode = None
            terminated = False
            killed = False
            waits = []
            stdout = FailingStdout()

            def poll(self):
                return self.returncode

            def terminate(self):
                self.terminated = True

            def wait(self, timeout=None):
                self.waits.append(timeout)
                self.returncode = -signal.SIGTERM
                return self.returncode

            def kill(self):
                self.killed = True

        process = CooperativeProcess()
        with patch("tests.live_recording_probe.subprocess.Popen", return_value=process):
            with self.assertRaisesRegex(RuntimeError, "synthetic read failure"):
                rms_windows(Path("unused"))

        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.terminated)
        self.assertFalse(process.killed)
        self.assertEqual(process.waits, [5.0])

    def test_sigterm_during_energy_wait_terminates_and_reaps_ffmpeg(self):
        class EmptyStdout:
            closed = False

            @staticmethod
            def read(_size):
                return b""

            def close(self):
                self.closed = True

        class WaitInterruptedProcess:
            returncode = None
            terminated = False
            killed = False
            waits = []
            stdout = EmptyStdout()

            def poll(self):
                return self.returncode

            def terminate(self):
                self.terminated = True

            def wait(self, timeout=None):
                self.waits.append(timeout)
                if timeout is None and len(self.waits) == 1:
                    os.kill(os.getpid(), signal.SIGTERM)
                self.returncode = -signal.SIGTERM
                return self.returncode

            def kill(self):
                self.killed = True

        process = WaitInterruptedProcess()
        with patch("tests.live_recording_probe.subprocess.Popen", return_value=process):
            with self.assertRaisesRegex(ProbeError, "probe_terminated"):
                with cleanup_aware_signal_handlers():
                    rms_windows(Path("unused"))

        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.terminated)
        self.assertFalse(process.killed)
        self.assertEqual(process.waits, [None, 5.0])

    def test_sigterm_unwinds_the_temporary_recording_store(self):
        temporary_path = None
        with self.assertRaisesRegex(ProbeError, "probe_terminated"):
            with cleanup_aware_signal_handlers():
                with tempfile.TemporaryDirectory(prefix="damso-live-recording-test-") as temporary:
                    temporary_path = Path(temporary)
                    temporary_path.joinpath("private-audio.caf").write_bytes(b"synthetic")
                    os.kill(os.getpid(), signal.SIGTERM)

        self.assertIsNotNone(temporary_path)
        self.assertFalse(temporary_path.exists())


class TranscriptCleanupTests(unittest.TestCase):
    def test_token_repetition_loop_is_collapsed(self):
        from damso.processing import collapse_repetitions

        looped = " ".join(["아"] * 223) + " 다시 이제 SF 쪽 다시 가신다고 하셔가지고"
        cleaned = collapse_repetitions(looped)
        self.assertEqual(cleaned.split().count("아"), 3)
        self.assertIn("다시 이제 SF 쪽", cleaned)

    def test_phrase_repetition_loop_is_collapsed(self):
        from damso.processing import collapse_repetitions

        looped = " ".join(["감사합니다 감사합니다"] * 10) + " 이어서 다음 안건입니다"
        cleaned = collapse_repetitions(looped)
        self.assertEqual(cleaned.split().count("감사합니다"), 3)
        self.assertIn("이어서 다음 안건입니다", cleaned)

    def test_normal_speech_is_untouched(self):
        from damso.processing import collapse_repetitions

        text = "네 네 맞아요 그 부분은 금요일까지 정리하고 다시 공유드릴게요"
        self.assertEqual(collapse_repetitions(text), text)

    def test_consecutive_identical_segments_are_capped(self):
        from damso.processing import clean_transcribed_segments

        segments = [{"start": float(i), "end": float(i + 1), "text": "시청해 주셔서 감사합니다"} for i in range(12)]
        segments.append({"start": 12.0, "end": 13.0, "text": "그럼 시작하겠습니다"})
        cleaned = clean_transcribed_segments(segments)
        self.assertEqual(len([s for s in cleaned if s["text"] == "시청해 주셔서 감사합니다"]), 2)
        self.assertEqual(cleaned[-1]["text"], "그럼 시작하겠습니다")

    def test_empty_segments_are_dropped(self):
        from damso.processing import clean_transcribed_segments

        cleaned = clean_transcribed_segments([{"start": 0.0, "end": 1.0, "text": "   "}])
        self.assertEqual(cleaned, [])


class InitialPromptTests(unittest.TestCase):
    def test_carrier_is_always_present_and_punctuated(self):
        prompt = build_initial_prompt(None, [])
        self.assertEqual(prompt, WHISPER_STYLE_CARRIER)
        self.assertIn(".", prompt)
        self.assertIn(",", prompt)

    def test_topic_and_terms_are_folded_into_whole_sentences(self):
        prompt = build_initial_prompt("분기 계획", ["하네스", "리팩토링"])
        self.assertTrue(prompt.startswith(WHISPER_STYLE_CARRIER))
        self.assertIn("이번 회의 주제는 분기 계획입니다.", prompt)
        self.assertIn("오늘은 하네스, 리팩토링 이야기를 나눕니다.", prompt)
        # A bare "주요 용어: a, b" list leaks verbatim into the first segment.
        self.assertNotIn("주요 용어", prompt)

    def test_blank_topic_and_terms_are_ignored(self):
        prompt = build_initial_prompt("   ", ["  ", ""])
        self.assertEqual(prompt, WHISPER_STYLE_CARRIER)

    def test_transcriber_sends_the_punctuated_prompt_to_its_worker(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            model = root / "model"
            model.mkdir()
            observed = {}

            class FakeConfig:
                mlx_whisper_model_directory = model

                @staticmethod
                def validate():
                    return None

            class FakeProcess:
                returncode = 0

                def __init__(self, arguments, **options):
                    pass

                def communicate(self, payload):
                    request = json.loads(payload)
                    observed["initial_prompt"] = request["initial_prompt"]
                    os.write(
                        request["output_fd"],
                        json.dumps([{"start": 0, "end": 1, "text": "hello"}]).encode("utf-8"),
                    )

            with patch("damso.processing.subprocess.Popen", side_effect=FakeProcess):
                MLXWhisperTranscriber(FakeConfig()).transcribe(
                    audio, {"topic": "분기 계획", "domain_terms": ["하네스"]}
                )

        self.assertIn(WHISPER_STYLE_CARRIER, observed["initial_prompt"])
        self.assertIn("분기 계획", observed["initial_prompt"])
        self.assertIn("하네스", observed["initial_prompt"])


class PromptNameSeedingTests(unittest.TestCase):
    def test_profile_labels_split_into_spoken_names(self):
        self.assertEqual(name_variants("송주은(오뜨)"), ["송주은", "오뜨"])
        self.assertEqual(name_variants("이재규"), ["이재규"])
        # The owner's own profile is stored under a pronoun that is never spoken.
        self.assertEqual(name_variants("나(이호연)"), ["이호연"])

    def test_profile_labels_are_normalized_from_filesystem_form(self):
        decomposed = unicodedata.normalize("NFD", "이재규")
        self.assertNotEqual(decomposed, "이재규")
        self.assertEqual(name_variants(decomposed), ["이재규"])

    def test_people_directory_is_listed_most_recent_first(self):
        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary)
            for index, name in enumerate(["older", "newer"]):
                person = peoples / name
                person.mkdir()
                os.utime(person, (1_000 + index, 1_000 + index))
            peoples.joinpath("archive").mkdir()
            peoples.joinpath(".hidden").mkdir()
            peoples.joinpath("loose.json").write_text("{}", encoding="utf-8")

            self.assertEqual(known_people_names(peoples), ["newer", "older"])

    def test_missing_people_directory_is_not_fatal(self):
        self.assertEqual(known_people_names(None), [])
        self.assertEqual(known_people_names(Path("/nonexistent-people-directory")), [])

    def test_participants_come_before_other_known_people(self):
        selected = select_prompt_names(["송주은(오뜨)"], ["이재규", "송주은"])
        self.assertEqual(selected[:2], ["송주은", "오뜨"])
        self.assertIn("이재규", selected)
        # "송주은" already arrived through the participant label.
        self.assertEqual(selected.count("송주은"), 1)

    def test_selection_stays_within_the_prompt_budget(self):
        many = [f"사람{index:02d}" for index in range(200)]
        selected = select_prompt_names([], many)
        self.assertLessEqual(len(selected), MAX_PROMPT_NAMES)
        self.assertLessEqual(sum(len(name) for name in selected), MAX_PROMPT_NAME_CHARS)

    def test_names_are_appended_as_a_sentence(self):
        prompt = build_initial_prompt(None, [], ["이재규", "송주은"])
        self.assertTrue(prompt.startswith(WHISPER_STYLE_CARRIER))
        self.assertIn("자주 언급되는 이름은 이재규, 송주은입니다.", prompt)

    def test_no_names_leaves_the_prompt_unchanged(self):
        self.assertEqual(build_initial_prompt(None, [], []), WHISPER_STYLE_CARRIER)



class NoiseSegmentTests(unittest.TestCase):
    def test_segments_without_hangul_or_alphanumerics_are_dropped(self):
        from damso.processing import normalize_mlx_segments

        segments = normalize_mlx_segments([
            {"start": 0.0, "end": 1.0, "text": "안녕하세요"},
            {"start": 1.0, "end": 2.0, "text": "!"},
            {"start": 2.0, "end": 3.0, "text": "вдруг"},
            {"start": 3.0, "end": 4.0, "text": "GitHub"},
            {"start": 4.0, "end": 5.0, "text": "천 вдруг"},
        ])
        self.assertEqual(
            [segment["text"] for segment in segments],
            ["안녕하세요", "GitHub", "천 вдруг"],
        )

    def test_inverted_spans_are_clamped_to_zero_length(self):
        from damso.processing import normalize_mlx_segments

        segments = normalize_mlx_segments(
            [{"start": 2141.06, "end": 2140.06, "text": "천"}]
        )
        self.assertEqual(segments[0]["start"], 2141.06)
        self.assertEqual(segments[0]["end"], 2141.06)


class BoundaryCacheTests(unittest.TestCase):
    def test_round_trips_intervals_indices_and_embeddings(self):
        import numpy as np

        from damso.processing import load_boundary_cache, save_boundary_cache

        with tempfile.TemporaryDirectory() as temporary:
            cache_path = Path(temporary) / "diarization-segments.npz"
            intervals = [{"start": 0.0, "end": 1.5}, {"start": 1.5, "end": 2.0}, {"start": 2.0, "end": 4.0}]
            vectors = np.asarray([[1.0, 0.0], [0.0, 1.0]], dtype=np.float32)
            save_boundary_cache(cache_path, 12_345, intervals, [0, 2], vectors)

            loaded = load_boundary_cache(cache_path, 12_345)
            self.assertIsNotNone(loaded)
            loaded_intervals, loaded_indices, loaded_vectors = loaded
            self.assertEqual(loaded_intervals, intervals)
            self.assertEqual(loaded_indices, [0, 2])
            self.assertTrue(np.array_equal(loaded_vectors, vectors))

    def test_misses_on_wrong_audio_size_missing_file_and_corrupt_content(self):
        import numpy as np

        from damso.processing import load_boundary_cache, save_boundary_cache

        with tempfile.TemporaryDirectory() as temporary:
            cache_path = Path(temporary) / "diarization-segments.npz"
            self.assertIsNone(load_boundary_cache(cache_path, 1))

            vectors = np.asarray([[1.0, 0.0]], dtype=np.float32)
            save_boundary_cache(cache_path, 12_345, [{"start": 0.0, "end": 1.0}], [0], vectors)
            self.assertIsNone(load_boundary_cache(cache_path, 99_999))

            cache_path.write_bytes(b"not an npz archive")
            self.assertIsNone(load_boundary_cache(cache_path, 12_345))

    def test_misses_when_indices_point_outside_the_interval_list(self):
        import numpy as np

        from damso.processing import load_boundary_cache, save_boundary_cache

        with tempfile.TemporaryDirectory() as temporary:
            cache_path = Path(temporary) / "diarization-segments.npz"
            vectors = np.asarray([[1.0, 0.0]], dtype=np.float32)
            save_boundary_cache(cache_path, 12_345, [{"start": 0.0, "end": 1.0}], [7], vectors)
            self.assertIsNone(load_boundary_cache(cache_path, 12_345))


class ReplayTranscriberTests(unittest.TestCase):
    def test_replays_start_end_text_and_ignores_extra_fields(self):
        from damso.processing import ReplayTranscriber

        transcriber = ReplayTranscriber([
            {"start": 0, "end": 2, "text": "first", "speaker": "SPEAKER_03"},
            {"start": 2.5, "end": 4, "text": "second"},
        ])
        segments = transcriber.transcribe(Path("unused"), {})
        self.assertEqual(segments, [
            {"start": 0.0, "end": 2.0, "text": "first"},
            {"start": 2.5, "end": 4.0, "text": "second"},
        ])
        # Each call returns fresh copies so a caller mutating one result
        # cannot corrupt a later replay.
        segments[0]["text"] = "mutated"
        self.assertEqual(transcriber.transcribe(Path("unused"), {})[0]["text"], "first")

    def test_recluster_replays_transcript_through_phase_one(self):
        from damso.processing import ReplayTranscriber

        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary) / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            audio = record / "microphone.caf"
            audio.write_bytes(b"synthetic")
            replay = ReplayTranscriber([
                {"start": 0, "end": 2, "text": "first", "speaker": "SPEAKER_05"},
                {"start": 4.5, "end": 6.0, "text": "second", "speaker": "SPEAKER_09"},
            ])
            pipeline = LocalProcessingPipeline(replay, FakeDiarizerWithEmbeddings())
            transcript = pipeline.run_phase_one(record, audio, {"num_speakers": 2})

            self.assertEqual(transcript["speakers"], ["SPEAKER_00", "SPEAKER_01"])
            self.assertEqual([segment["text"] for segment in transcript["segments"]], ["first", "second"])
            written = json.loads((record / "transcript.raw.json").read_text(encoding="utf-8"))
            self.assertEqual(written["speakers"], ["SPEAKER_00", "SPEAKER_01"])
            hint = json.loads((record / "hint.json").read_text(encoding="utf-8"))
            self.assertEqual(hint["num_speakers"], 2)


if __name__ == "__main__":
    unittest.main()
