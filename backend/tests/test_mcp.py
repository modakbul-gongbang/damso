import inspect
import json
import tempfile
import unittest
from pathlib import Path

from damso import mcp
from damso.mcp import ReadOnlyStore, dispatch


LEGACY_SEARCH_KEYS = {"stem", "title", "source", "createdAt", "durationSeconds", "stage", "sensitive"}


def make_store(root: Path) -> ReadOnlyStore:
    record_dir = root / "Plaud" / "recordings" / "fixture"
    record_dir.mkdir(parents=True)
    record_dir.joinpath("meeting.json").write_text(
        json.dumps(
            {
                "stem": "fixture",
                "title": "Synthetic review",
                "source": "local",
                "createdAt": "2026-07-14T00:00:00Z",
                "stage": "complete",
                "resolutions": [{"speaker": "SPEAKER_00", "action": "match", "personName": "Kim Partner"}],
                "summary": {"one_line_summary": "Synthetic summary", "key_points": ["One point"]},
                "transcript": [{"speaker": "Kim Partner", "text": "keyword text"}],
            }
        ),
        encoding="utf-8",
    )
    record_dir.joinpath("transcript.raw.json").write_text(
        json.dumps({"segments": [{"speaker": "SPEAKER_00", "start": 0, "end": 1, "text": "keyword text"}]}),
        encoding="utf-8",
    )
    profile = root / "Plaud" / "peoples" / "Kim-Partner" / "profile.md"
    profile.parent.mkdir(parents=True)
    profile.write_text("---\nname: \"Kim Partner\"\n---\n## Notes\nSynthetic profile.\n", encoding="utf-8")
    owner = root / "Plaud" / "me" / "profile.md"
    owner.parent.mkdir(parents=True)
    owner.write_text("---\nname: \"Owner\"\n---\n## Notes\nSynthetic owner profile.\n", encoding="utf-8")
    return ReadOnlyStore(root)


class MCPTests(unittest.TestCase):
    def test_search_and_read_are_local_and_non_mutating(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)
            record_path = root / "Plaud" / "recordings" / "fixture" / "meeting.json"
            before = record_path.read_bytes()
            response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"date": "2026-07-14", "speaker": "Kim", "keyword": "keyword"}}})

            payload = json.loads(response["result"]["content"][0]["text"])
            self.assertEqual(payload[0]["stem"], "fixture")
            self.assertEqual(before, record_path.read_bytes())
            definitions = dispatch(store, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})["result"]["tools"]
            self.assertEqual({item["name"] for item in definitions}, {"search_meetings", "get_meeting", "get_speaker"})
            self.assertTrue(all(not item["name"].startswith(("write", "update", "delete")) for item in definitions))
            meeting = dispatch(store, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_meeting", "arguments": {"stem": "fixture"}}})
            meeting_payload = json.loads(meeting["result"]["content"][0]["text"])
            self.assertEqual(meeting_payload["summary"]["one_line_summary"], "Synthetic summary")
            self.assertEqual(meeting_payload["transcript"], [{"speaker": "Kim Partner", "text": "keyword text"}])
            speaker = dispatch(store, {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "get_speaker", "arguments": {"name": "Kim Partner"}}})
            speaker_payload = json.loads(speaker["result"]["content"][0]["text"])
            self.assertIn("Synthetic profile.", speaker_payload["profile"])
            self.assertEqual([meeting["stem"] for meeting in speaker_payload["meetings"]], ["fixture"])
            owner_result = dispatch(store, {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "get_speaker", "arguments": {"name": "Owner"}}})
            self.assertIn("Synthetic owner profile.", owner_result["result"]["content"][0]["text"])
            self.assertNotIn("socket", inspect.getsource(mcp))

    def test_legacy_response_schema_is_preserved_with_additive_fields_only(self):
        """MCP contract regression: existing clients rely on the original keys.

        Every legacy search_meetings key must stay present, and new fields may
        only be added on top (D-18: additive-only compatibility).
        """
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))
            response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {}}})
            item = json.loads(response["result"]["content"][0]["text"])[0]
            self.assertTrue(LEGACY_SEARCH_KEYS.issubset(item.keys()))
            self.assertIsInstance(item["sensitive"], bool)
            self.assertEqual(item["displayTitle"], item["title"])
            meeting = dispatch(store, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "get_meeting", "arguments": {"stem": "fixture"}}})
            meeting_payload = json.loads(meeting["result"]["content"][0]["text"])
            self.assertEqual(set(meeting_payload.keys()), {"metadata", "summary", "transcript"})
            self.assertTrue(LEGACY_SEARCH_KEYS.issubset(meeting_payload["metadata"].keys()))
            speaker = dispatch(store, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "get_speaker", "arguments": {"name": "Kim Partner"}}})
            speaker_payload = json.loads(speaker["result"]["content"][0]["text"])
            self.assertEqual(set(speaker_payload.keys()), {"name", "profile", "meetings"})

    def test_search_uses_the_sqlite_index_backend(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)
            store.search()
            self.assertTrue((root / "index.sqlite3").is_file())
            missing = dispatch(store, {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"keyword": "absent-keyword"}}})
            self.assertEqual(json.loads(missing["result"]["content"][0]["text"]), [])


if __name__ == "__main__":
    unittest.main()
