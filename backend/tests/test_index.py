import json
import sqlite3
import tempfile
import unicodedata
import unittest
from pathlib import Path
from unittest import mock

from damso import index as index_module
from damso.index import SCHEMA_VERSION, build_index, index_path, open_index


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

    def test_nfd_decomposed_people_directory_name_matches_nfc_typed_keyword(self):
        # macOS stores Plaud/peoples directory names NFD-decomposed
        # (agents/rules/INDEX.md#FACT-peoples-directory-nfd); the index must
        # NFC-normalize on the way in so an NFC-typed query still matches.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = root / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            record.joinpath("meeting.json").write_text(
                json.dumps({"stem": "fixture", "title": "회의", "source": "local", "createdAt": "2026-08-06T00:00:00Z", "stage": "complete"}),
                encoding="utf-8",
            )
            nfd_name = unicodedata.normalize("NFD", "김파트너")
            profile = root / "Plaud" / "peoples" / nfd_name / "profile.md"
            profile.parent.mkdir(parents=True)
            profile.write_text(
                '---\nname: "김파트너"\n---\n## Description\n\n## Meetings\n\n## Notes\n- (2026-08-06) 가격협상에 관심\n',
                encoding="utf-8",
            )
            build_index(root)
            connection = open_index(root, rebuild_if_missing=False)
            try:
                nfc_query = unicodedata.normalize("NFC", "가격협상")
                rows = connection.execute(
                    "SELECT p.name FROM people p JOIN people_fts ON people_fts.rowid = p.rowid WHERE people_fts MATCH ?",
                    (f'"{nfc_query}"',),
                ).fetchall()
                self.assertEqual([row["name"] for row in rows], ["김파트너"])
                person = connection.execute("SELECT slug FROM people").fetchone()
                self.assertEqual(person["slug"], unicodedata.normalize("NFC", nfd_name))
            finally:
                connection.close()

    def test_open_index_auto_rebuilds_synchronously_on_stale_schema_without_data_loss(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = make_store(Path(temporary))
            build_index(root)
            connection = sqlite3.connect(index_path(root))
            try:
                connection.execute("UPDATE meta SET value = '1' WHERE key = 'schema_version'")
                connection.commit()
            finally:
                connection.close()

            connection = open_index(root)
            try:
                version = connection.execute("SELECT value FROM meta WHERE key = 'schema_version'").fetchone()
                self.assertEqual(version[0], str(SCHEMA_VERSION))
                meeting = connection.execute("SELECT stem FROM meetings").fetchone()
                self.assertEqual(meeting["stem"], "fixture")
                fts_tables = {
                    row[0]
                    for row in connection.execute(
                        "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('meetings_fts', 'people_fts')"
                    ).fetchall()
                }
                self.assertEqual(fts_tables, {"meetings_fts", "people_fts"})
            finally:
                connection.close()

    def test_fts5_creation_failure_still_builds_core_tables_and_records_unavailable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = make_store(Path(temporary))
            with mock.patch.object(index_module, "SCHEMA_FTS", "CREATE VIRTUAL TABLE meetings_fts USING fts5(searchable, tokenize='no-such-tokenizer');"):
                result = build_index(root)
            self.assertTrue(result["ok"])
            self.assertFalse(result["fts5_available"])
            connection = open_index(root, rebuild_if_missing=False)
            try:
                flag = connection.execute("SELECT value FROM meta WHERE key = 'fts5_available'").fetchone()
                self.assertEqual(flag[0], "0")
                meeting = connection.execute("SELECT stem FROM meetings").fetchone()
                self.assertEqual(meeting["stem"], "fixture")
                person = connection.execute("SELECT name FROM people").fetchone()
                self.assertEqual(person["name"], "김구름")
                tables = {
                    row[0]
                    for row in connection.execute(
                        "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('meetings_fts', 'people_fts')"
                    ).fetchall()
                }
                self.assertEqual(tables, set())
            finally:
                connection.close()


if __name__ == "__main__":
    unittest.main()
