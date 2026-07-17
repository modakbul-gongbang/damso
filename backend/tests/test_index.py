import json
import tempfile
import unittest
from pathlib import Path

from damso.index import build_index, index_path, open_index


def make_store(root: Path) -> Path:
    record = root / "Plaud" / "recordings" / "fixture"
    record.mkdir(parents=True)
    record.joinpath("meeting.json").write_text(
        json.dumps(
            {
                "stem": "fixture",
                "title": "2026071419-온보딩 워크숍 커리큘럼 논의",
                "source": "local",
                "createdAt": "2026-07-14T19:00:00Z",
                "durationSeconds": 1794.0,
                "stage": "complete",
                "resolutions": [
                    {"speaker": "SPEAKER_00", "action": "match", "personName": "김구름"},
                    {"speaker": "SPEAKER_01", "action": "skip", "personName": None},
                ],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    record.joinpath("summary.json").write_text(
        json.dumps({"title": "온보딩 워크숍 커리큘럼 논의", "one_line_summary": "커리큘럼 초안 합의"}, ensure_ascii=False),
        encoding="utf-8",
    )
    record.joinpath("transcript.raw.json").write_text(
        json.dumps({"segments": [{"speaker": "SPEAKER_00", "start": 0, "end": 2, "text": "인스타 스토리 공유"}]}, ensure_ascii=False),
        encoding="utf-8",
    )
    profile = root / "Plaud" / "peoples" / "김구름" / "profile.md"
    profile.parent.mkdir(parents=True)
    profile.write_text(
        '---\nname: "김구름"\nmeeting_count: 1\nfirst_seen: "2026-07-14"\nlast_seen: "2026-07-14"\n---\n## Notes\n',
        encoding="utf-8",
    )
    return root


class IndexTests(unittest.TestCase):
    def test_build_indexes_meetings_participants_and_people(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = make_store(Path(temporary))
            result = build_index(root)
            self.assertTrue(result["ok"])
            connection = open_index(root, rebuild_if_missing=False)
            try:
                meeting = connection.execute("SELECT * FROM meetings").fetchone()
                self.assertEqual(meeting["stem"], "fixture")
                self.assertEqual(meeting["title"], "2026071419-온보딩 워크숍 커리큘럼 논의")
                self.assertIn("인스타 스토리", meeting["searchable"])
                participants = connection.execute("SELECT person FROM participants").fetchall()
                self.assertEqual([row["person"] for row in participants], ["김구름"])
                person = connection.execute("SELECT * FROM people WHERE name = ?", ("김구름",)).fetchone()
                self.assertEqual(person["meeting_count"], 1)
                self.assertEqual(person["has_voice_profile"], 0)
            finally:
                connection.close()

    def test_skipped_speakers_never_become_participants(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = make_store(Path(temporary))
            build_index(root)
            connection = open_index(root, rebuild_if_missing=False)
            try:
                rows = connection.execute("SELECT speaker_label FROM participants").fetchall()
                self.assertEqual([row["speaker_label"] for row in rows], ["SPEAKER_00"])
            finally:
                connection.close()

    def test_rebuild_after_delete_restores_identical_rows_without_llm(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = make_store(Path(temporary))
            build_index(root)

            def snapshot():
                connection = open_index(root, rebuild_if_missing=False)
                try:
                    meetings = connection.execute("SELECT stem, title, created_at, stage FROM meetings ORDER BY stem").fetchall()
                    participants = connection.execute("SELECT stem, person FROM participants ORDER BY stem, person").fetchall()
                    people = connection.execute("SELECT slug, name, meeting_count FROM people ORDER BY slug").fetchall()
                    return (
                        [tuple(row) for row in meetings],
                        [tuple(row) for row in participants],
                        [tuple(row) for row in people],
                    )
                finally:
                    connection.close()

            before = snapshot()
            index_path(root).unlink()
            build_index(root)
            self.assertEqual(before, snapshot())


if __name__ == "__main__":
    unittest.main()
