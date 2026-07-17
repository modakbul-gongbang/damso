import json
import tempfile
import unittest
from pathlib import Path

from damso import reconcile

OWNER = "소리"


def _write(directory: Path, transcript: dict, resolutions_yaml: str | None = None) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "transcript.json").write_text(json.dumps(transcript, ensure_ascii=False), encoding="utf-8")
    if resolutions_yaml is not None:
        (directory / "resolutions.yaml").write_text(resolutions_yaml, encoding="utf-8")


LEGACY_TRANSCRIPT = {
    "source_file": "audio.ogg",
    "language": "ko",
    "model": "large-v3",
    "duration": 30.0,
    "speakers": [OWNER, "박바람"],
    "identified": {"SPEAKER_00": OWNER, "SPEAKER_01": "박바람"},
    "segments": [
        {"speaker": OWNER, "start": 0.0, "end": 5.0, "text": "안녕하세요"},
        {"speaker": "박바람", "start": 5.0, "end": 12.0, "text": "네 반갑습니다"},
        {"speaker": "UNKNOWN", "start": 12.0, "end": 15.0, "text": "잡음"},
    ],
}


class ReconcileTests(unittest.TestCase):
    def setUp(self):
        self._saved_me_name = reconcile.ME_NAME
        reconcile.ME_NAME = OWNER

    def tearDown(self):
        reconcile.ME_NAME = self._saved_me_name

    def test_reconcile_with_resolutions_yaml(self):
        with tempfile.TemporaryDirectory() as tmp:
            rec = Path(tmp) / "2026-05-25_rec"
            _write(
                rec,
                LEGACY_TRANSCRIPT,
                "speakers:\n  SPEAKER_00:\n    action: me\n    name: 소리\n  SPEAKER_01:\n    action: new\n    name: 박바람\n",
            )
            result = reconcile.reconcile_record(rec)
            self.assertEqual(result.status, "reconciled")

            raw = json.loads((rec / "transcript.raw.json").read_text(encoding="utf-8"))
            # Resolved names are mapped back to SPEAKER_XX; UNKNOWN stays.
            self.assertEqual(
                [s["speaker"] for s in raw["segments"]],
                ["SPEAKER_00", "SPEAKER_01", "UNKNOWN"],
            )
            self.assertEqual(raw["speakers"], ["SPEAKER_00", "SPEAKER_01", "UNKNOWN"])

            ident = json.loads((rec / "identification.json").read_text(encoding="utf-8"))
            self.assertEqual(ident["proposals"]["SPEAKER_00"]["candidates"][0]["name"], OWNER)
            self.assertEqual(ident["proposals"]["UNKNOWN"]["candidates"], [])

            by_speaker = {r["speaker"]: r for r in result.resolutions}
            # "me" links to the person "나", matching previously imported records.
            self.assertEqual(by_speaker["SPEAKER_00"], {"action": "me", "personName": "나", "speaker": "SPEAKER_00"})
            self.assertEqual(by_speaker["SPEAKER_01"], {"action": "new", "personName": "박바람", "speaker": "SPEAKER_01"})
            self.assertEqual(by_speaker["UNKNOWN"], {"action": "skip", "speaker": "UNKNOWN"})

    def test_reconcile_without_yaml_uses_identified(self):
        with tempfile.TemporaryDirectory() as tmp:
            rec = Path(tmp) / "2026-04-14_rec"
            _write(rec, LEGACY_TRANSCRIPT)
            result = reconcile.reconcile_record(rec)
            self.assertEqual(result.status, "reconciled")
            by_speaker = {r["speaker"]: r for r in result.resolutions}
            # the owner name -> me/나 even without a yaml; other identified -> match.
            self.assertEqual(by_speaker["SPEAKER_00"], {"action": "me", "personName": "나", "speaker": "SPEAKER_00"})
            self.assertEqual(by_speaker["SPEAKER_01"], {"action": "match", "personName": "박바람", "speaker": "SPEAKER_01"})

    def test_idempotent_skip(self):
        with tempfile.TemporaryDirectory() as tmp:
            rec = Path(tmp) / "rec"
            _write(rec, LEGACY_TRANSCRIPT)
            reconcile.reconcile_record(rec)
            again = reconcile.reconcile_record(rec)
            self.assertEqual(again.status, "skipped")

    def test_speaker_collision_keeps_lowest_index(self):
        transcript = dict(LEGACY_TRANSCRIPT)
        transcript["identified"] = {"SPEAKER_01": "최하늘", "SPEAKER_02": "최하늘"}
        transcript["segments"] = [{"speaker": "최하늘", "start": 0.0, "end": 4.0, "text": "테스트"}]
        with tempfile.TemporaryDirectory() as tmp:
            rec = Path(tmp) / "rec"
            _write(rec, transcript)
            reconcile.reconcile_record(rec)
            raw = json.loads((rec / "transcript.raw.json").read_text(encoding="utf-8"))
            self.assertEqual(raw["segments"][0]["speaker"], "SPEAKER_01")

    def test_clamps_reversed_timestamps(self):
        transcript = dict(LEGACY_TRANSCRIPT)
        transcript["segments"] = [{"speaker": "UNKNOWN", "start": 633.88, "end": 625.58, "text": "글리치"}]
        with tempfile.TemporaryDirectory() as tmp:
            rec = Path(tmp) / "rec"
            _write(rec, transcript)
            result = reconcile.reconcile_record(rec)
            self.assertEqual(result.status, "reconciled")
            import json as _json
            raw = _json.loads((rec / "transcript.raw.json").read_text(encoding="utf-8"))
            seg = raw["segments"][0]
            self.assertGreaterEqual(seg["end"], seg["start"])


if __name__ == "__main__":
    unittest.main()


class ExcerptBackfillTests(unittest.TestCase):
    def test_backfill_fills_empty_excerpts_from_transcript(self):
        with tempfile.TemporaryDirectory() as tmp:
            rec = Path(tmp) / "rec"
            rec.mkdir()
            raw = {
                "source_file": "a.ogg", "language": "ko", "model": "large-v3", "duration": 40.0,
                "speakers": ["SPEAKER_00", "SPEAKER_01"],
                "segments": [
                    {"speaker": "SPEAKER_00", "start": 0.0, "end": 9.0, "text": "긴 발언 하나"},
                    {"speaker": "SPEAKER_00", "start": 9.0, "end": 10.0, "text": "짧음"},
                    {"speaker": "SPEAKER_01", "start": 10.0, "end": 25.0, "text": "상대방 발언"},
                ],
            }
            (rec / "transcript.raw.json").write_text(json.dumps(raw), encoding="utf-8")
            (rec / "identification.json").write_text(json.dumps({
                "version": 1,
                "proposals": {"SPEAKER_00": {"candidates": [], "excerpts": []},
                              "SPEAKER_01": {"candidates": []}},
            }), encoding="utf-8")

            result = reconcile.backfill_excerpts(rec)
            self.assertEqual(result.status, "reconciled")
            ident = json.loads((rec / "identification.json").read_text(encoding="utf-8"))
            s0 = ident["proposals"]["SPEAKER_00"]["excerpts"]
            self.assertEqual(len(s0), 1)  # only the >=1.5s segment qualifies
            self.assertEqual(s0[0]["text"], "긴 발언 하나")
            self.assertEqual(len(ident["proposals"]["SPEAKER_01"]["excerpts"]), 1)

            # Idempotent: a second run changes nothing.
            self.assertEqual(reconcile.backfill_excerpts(rec).status, "skipped")
