import inspect
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from damso import mcp
from damso.index import index_path
from damso.mcp import PROTOCOL_VERSION, ReadOnlyStore, dispatch


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
        json.dumps({"segments": [{"speaker": "SPEAKER_00", "start": 0, "end": 1, "text": "keyword text milestone"}]}),
        encoding="utf-8",
    )
    profile = root / "Plaud" / "peoples" / "Kim-Partner" / "profile.md"
    profile.parent.mkdir(parents=True)
    profile.write_text(
        "---\nname: \"Kim Partner\"\n---\n## Description\n\n## Meetings\n\n## Notes\nSynthetic profile. Interested in the roadmap discussion.\n",
        encoding="utf-8",
    )
    owner = root / "Plaud" / "me" / "profile.md"
    owner.parent.mkdir(parents=True)
    owner.write_text("---\nname: \"Owner\"\n---\n## Notes\nSynthetic owner profile.\n", encoding="utf-8")
    return ReadOnlyStore(root)


class MCPTests(unittest.TestCase):
    def test_initialize_handshake_answers_before_any_tool_call(self):
        """A compliant MCP client sends `initialize` first and refuses to go
        further without a valid result. Answering it with -32601 (which this
        server did until the endpoint was first tried against a real client)
        means no client can ever reach `tools/list`, no matter how correct the
        tools themselves are."""
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))
            response = dispatch(store, {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "c", "version": "0"}},
            })

            self.assertNotIn("error", response)
            result = response["result"]
            self.assertEqual(result["protocolVersion"], "2025-06-18")
            self.assertIn("tools", result["capabilities"])
            self.assertEqual(result["serverInfo"]["name"], "damso")

    def test_initialize_falls_back_to_our_latest_for_an_unknown_revision(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))
            response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "1999-01-01"}})

            self.assertEqual(response["result"]["protocolVersion"], PROTOCOL_VERSION)

    def test_notifications_get_no_reply_and_ping_gets_an_empty_result(self):
        """A notification has no `id` and by definition takes no response;
        replying to one with a null-id envelope makes a strict client treat
        the stream as malformed."""
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))

            self.assertIsNone(dispatch(store, {"jsonrpc": "2.0", "method": "notifications/initialized"}))
            self.assertEqual(dispatch(store, {"jsonrpc": "2.0", "id": 7, "method": "ping"})["result"], {})

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
            self.assertEqual({item["name"] for item in definitions}, {"search_meetings", "get_meeting", "get_speaker", "search_people"})
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

    def test_search_meetings_keyword_adds_snippet_and_ranks_by_relevance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)
            frequent_dir = root / "Plaud" / "recordings" / "fixture-frequent"
            frequent_dir.mkdir(parents=True)
            frequent_dir.joinpath("meeting.json").write_text(
                json.dumps(
                    {
                        "stem": "fixture-frequent",
                        "title": "Milestone planning",
                        "source": "local",
                        "createdAt": "2026-07-10T00:00:00Z",
                        "stage": "complete",
                    }
                ),
                encoding="utf-8",
            )
            frequent_dir.joinpath("transcript.raw.json").write_text(
                json.dumps(
                    {
                        "segments": [
                            {
                                "speaker": "SPEAKER_00",
                                "start": 0,
                                "end": 1,
                                "text": "milestone milestone milestone the milestone review covers every milestone on the roadmap",
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )
            response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"keyword": "milestone"}}})
            payload = json.loads(response["result"]["content"][0]["text"])
            self.assertEqual([item["stem"] for item in payload], ["fixture-frequent", "fixture"])
            for item in payload:
                self.assertIn("snippet", item)
                self.assertTrue(LEGACY_SEARCH_KEYS.issubset(item.keys()))
            self.assertIn("milestone", payload[0]["snippet"].lower())

    def test_search_meetings_short_keyword_falls_back_to_substring_match_with_snippet(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)
            # "ke" is below the trigram tokenizer's 3-character floor.
            response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"keyword": "ke"}}})
            payload = json.loads(response["result"]["content"][0]["text"])
            self.assertEqual([item["stem"] for item in payload], ["fixture"])
            self.assertIn("snippet", payload[0])

    def test_search_people_matches_profile_notes_and_returns_empty_array_for_no_match(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)
            found = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_people", "arguments": {"keyword": "roadmap"}}})
            payload = json.loads(found["result"]["content"][0]["text"])
            self.assertEqual(len(payload), 1)
            self.assertEqual(payload[0]["name"], "Kim Partner")
            self.assertEqual(set(payload[0].keys()), {"name", "slug", "meetingCount", "snippet"})
            self.assertIn("roadmap", payload[0]["snippet"].lower())

            empty = dispatch(store, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "search_people", "arguments": {"keyword": "nonexistent-term"}}})
            self.assertEqual(json.loads(empty["result"]["content"][0]["text"]), [])

    def test_fts5_unavailable_fails_keyword_search_explicitly_but_other_tools_keep_working(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)
            store.search()  # build the index once
            connection = sqlite3.connect(index_path(root))
            try:
                connection.execute("UPDATE meta SET value = '0' WHERE key = 'fts5_available'")
                connection.commit()
            finally:
                connection.close()

            keyword_search = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"keyword": "keyword"}}})
            self.assertIn("error", keyword_search)

            people_search = dispatch(store, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "search_people", "arguments": {"keyword": "roadmap"}}})
            self.assertIn("error", people_search)

            plain_search = dispatch(store, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"date": "2026-07-14"}}})
            self.assertNotIn("error", plain_search)
            self.assertEqual(json.loads(plain_search["result"]["content"][0]["text"])[0]["stem"], "fixture")

            meeting = dispatch(store, {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "get_meeting", "arguments": {"stem": "fixture"}}})
            self.assertNotIn("error", meeting)

            speaker = dispatch(store, {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "get_speaker", "arguments": {"name": "Kim Partner"}}})
            self.assertNotIn("error", speaker)


if __name__ == "__main__":
    unittest.main()
