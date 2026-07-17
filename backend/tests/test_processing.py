import json
import tempfile
import unittest
from pathlib import Path

from damso.people import VOICE_EMBEDDING_MODEL, apply_people_resolutions, read_profile
from damso.processing import LocalProcessingPipeline, assign_speakers, read_speaker_embeddings


class FakeTranscriber:
    def transcribe(self, audio_path, hints):
        return [{"start": 0, "end": 2, "text": "first"}, {"start": 2.2, "end": 4, "text": "second"}, {"start": 5, "end": 6, "text": "third"}]


class FakeDiarizer:
    def diarize(self, audio_path, num_speakers):
        return [{"start": 0, "end": 4.2, "speaker": "SPEAKER_00"}, {"start": 4.5, "end": 6.5, "speaker": "SPEAKER_01"}]


class FakeDiarizerWithEmbeddings(FakeDiarizer):
    def speaker_embeddings(self, audio_path, intervals):
        return {"SPEAKER_00": [1.0, 0.0], "SPEAKER_01": [0.0, 1.0]}


class ProcessingTests(unittest.TestCase):
    def test_local_phase_one_writes_provisional_contract_with_speaker_cards(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            audio = root / "audio.caf"
            audio.write_bytes(b"synthetic")
            record = root / "record"
            result = LocalProcessingPipeline(FakeTranscriber(), FakeDiarizer()).run_phase_one(record, audio, {"participants": ["Kim"], "num_speakers": 2})
            identification = json.loads(record.joinpath("identification.json").read_text(encoding="utf-8"))
            self.assertEqual(result["speakers"], ["SPEAKER_00", "SPEAKER_01"])
            self.assertEqual(len(identification["proposals"]["SPEAKER_00"]["excerpts"]), 1)
            self.assertTrue(record.joinpath("transcript.raw.json").is_file())
            self.assertTrue(record.joinpath("transcript.md").is_file())

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
