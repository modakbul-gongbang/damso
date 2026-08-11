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
            # R4: `meeting.json` never carries the transcript itself; the
            # segments come from transcript.raw.json (transcript.json is
            # absent in this fixture, so raw is the base).
            self.assertEqual(
                meeting_payload["transcript"],
                [{"speaker": "SPEAKER_00", "start": 0, "end": 1, "text": "keyword text milestone"}],
            )
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

    def test_get_meeting_prefers_transcript_json_over_raw_when_both_exist(self):
        """transcript.json carries resolved speaker names (transcript.raw.json
        still has raw SPEAKER_00-style labels) - that's the one a person, and
        so an AI reading on their behalf, actually wants."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)
            record_dir = root / "Plaud" / "recordings" / "fixture"
            record_dir.joinpath("transcript.json").write_text(
                json.dumps({"segments": [{"speaker": "Kim Partner", "start": 0, "end": 1, "text": "resolved text"}]}),
                encoding="utf-8",
            )
            meeting = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_meeting", "arguments": {"stem": "fixture"}}})
            payload = json.loads(meeting["result"]["content"][0]["text"])
            self.assertEqual(payload["transcript"], [{"speaker": "Kim Partner", "start": 0, "end": 1, "text": "resolved text"}])

    def test_get_meeting_applies_a_matching_cleanup_overlay(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record_dir = root / "Plaud" / "recordings" / "overlay-fixture"
            record_dir.mkdir(parents=True)
            record_dir.joinpath("meeting.json").write_text(json.dumps({"stem": "overlay-fixture", "title": "t", "source": "local", "createdAt": "2026-08-01T00:00:00Z", "stage": "complete"}), encoding="utf-8")
            record_dir.joinpath("transcript.json").write_text(
                json.dumps({"generation_id": "gen-A", "segments": [{"speaker": "S1", "start": 0, "end": 1, "text": "um so anyway hi"}]}),
                encoding="utf-8",
            )
            record_dir.joinpath("transcript.cleaned.json").write_text(
                json.dumps({"generation_id": "gen-A", "corrections": [{"index": 0, "text": "hi"}]}),
                encoding="utf-8",
            )
            store = ReadOnlyStore(root)
            meeting = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_meeting", "arguments": {"stem": "overlay-fixture"}}})
            payload = json.loads(meeting["result"]["content"][0]["text"])
            self.assertEqual(payload["transcript"][0]["text"], "hi")

    def test_get_meeting_ignores_a_stale_cleanup_overlay(self):
        """A recluster rewrites transcript.json with a new generation_id and
        different segmentation; an overlay bound to the old generation_id no
        longer aligns and must not be applied by index to the wrong
        segments."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record_dir = root / "Plaud" / "recordings" / "stale-overlay-fixture"
            record_dir.mkdir(parents=True)
            record_dir.joinpath("meeting.json").write_text(json.dumps({"stem": "stale-overlay-fixture", "title": "t", "source": "local", "createdAt": "2026-08-01T00:00:00Z", "stage": "complete"}), encoding="utf-8")
            record_dir.joinpath("transcript.json").write_text(
                json.dumps({"generation_id": "gen-B", "segments": [{"speaker": "S1", "start": 0, "end": 1, "text": "um so anyway hi"}]}),
                encoding="utf-8",
            )
            record_dir.joinpath("transcript.cleaned.json").write_text(
                json.dumps({"generation_id": "gen-OLD", "corrections": [{"index": 0, "text": "hi"}]}),
                encoding="utf-8",
            )
            store = ReadOnlyStore(root)
            meeting = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_meeting", "arguments": {"stem": "stale-overlay-fixture"}}})
            payload = json.loads(meeting["result"]["content"][0]["text"])
            self.assertEqual(payload["transcript"][0]["text"], "um so anyway hi")

    def test_search_meetings_rejects_a_malformed_date_instead_of_returning_an_empty_list(self):
        """Before this, "August 2026" and "2026" behaved identically -
        both silently produced zero rows, so a caller could never tell a
        typo apart from a genuinely empty month."""
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))
            for bad_date in ("August 2026", "2026-13", "26-08", ""):
                response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"date": bad_date}}})
                self.assertNotIn("error", response, bad_date)
                self.assertTrue(response["result"].get("isError"), bad_date)
                self.assertIn("date", response["result"]["content"][0]["text"])

            for good_date in ("2026", "2026-08", "2026-08-11"):
                response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"date": good_date}}})
                self.assertFalse(response["result"].get("isError"), good_date)

    def test_get_meeting_reports_an_unknown_stem_as_a_tool_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))
            response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_meeting", "arguments": {"stem": "주간 회의"}}})
            self.assertNotIn("error", response)
            self.assertTrue(response["result"]["isError"])
            self.assertIn("주간 회의", response["result"]["content"][0]["text"])
            self.assertIn("search_meetings", response["result"]["content"][0]["text"])

    def test_get_speaker_reports_an_unknown_name_as_a_tool_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))
            response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_speaker", "arguments": {"name": "Nobody Here"}}})
            self.assertNotIn("error", response)
            self.assertTrue(response["result"]["isError"])
            self.assertIn("search_people", response["result"]["content"][0]["text"])

    def test_get_speaker_meetings_excludes_a_meeting_credited_only_to_an_unrelated_substring_match(self):
        """`participants.person` holds resolved, canonical person names (from
        meeting.json's own `resolutions`), not raw live-captured display
        names - a substring match against it only ever produces false
        positives. Reproduces the exact failure observed against the real
        store: asking for a common single-syllable Korean name attached
        meetings credited to a completely different person whose resolved
        name merely contained that syllable."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)  # "fixture" is credited to "Kim Partner"
            unrelated_dir = root / "Plaud" / "recordings" / "unrelated"
            unrelated_dir.mkdir(parents=True)
            unrelated_dir.joinpath("meeting.json").write_text(
                json.dumps(
                    {
                        "stem": "unrelated",
                        "title": "Someone else's meeting",
                        "source": "local",
                        "createdAt": "2026-07-15T00:00:00Z",
                        "stage": "complete",
                        # "Kim Anderson" contains "Kim" as a substring but is
                        # a different, unrelated person from "Kim Partner".
                        "resolutions": [{"speaker": "SPEAKER_00", "action": "match", "personName": "Kim Anderson"}],
                    }
                ),
                encoding="utf-8",
            )
            speaker = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_speaker", "arguments": {"name": "Kim Partner"}}})
            payload = json.loads(speaker["result"]["content"][0]["text"])
            self.assertEqual([meeting["stem"] for meeting in payload["meetings"]], ["fixture"])

            # The substring-matching browse path (search_meetings) is
            # unchanged and legitimately still finds both.
            browse = dispatch(store, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"speaker": "Kim"}}})
            browse_payload = json.loads(browse["result"]["content"][0]["text"])
            self.assertEqual({item["stem"] for item in browse_payload}, {"fixture", "unrelated"})

    def test_search_meetings_defaults_to_a_bounded_page_and_honors_limit_and_offset(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)
            for index in range(25):
                extra_dir = root / "Plaud" / "recordings" / f"extra-{index:02d}"
                extra_dir.mkdir(parents=True)
                extra_dir.joinpath("meeting.json").write_text(
                    json.dumps({"stem": f"extra-{index:02d}", "title": "t", "source": "local", "createdAt": f"2026-07-{index + 1:02d}T00:00:00Z", "stage": "complete"}),
                    encoding="utf-8",
                )
            default_page = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {}}})
            default_payload = json.loads(default_page["result"]["content"][0]["text"])
            self.assertEqual(len(default_payload), 20)  # 26 total meetings (25 + "fixture"), default limit is 20

            small_page = dispatch(store, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"limit": 5}}})
            small_payload = json.loads(small_page["result"]["content"][0]["text"])
            self.assertEqual(len(small_payload), 5)

            next_page = dispatch(store, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"limit": 5, "offset": 5}}})
            next_payload = json.loads(next_page["result"]["content"][0]["text"])
            self.assertEqual(len(next_payload), 5)
            self.assertNotEqual({item["stem"] for item in small_payload}, {item["stem"] for item in next_payload})

    def test_search_meetings_rejects_an_out_of_range_or_malformed_limit(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))
            for bad_limit in (0, -1, 101, "twenty"):
                response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"limit": bad_limit}}})
                self.assertNotIn("error", response, bad_limit)
                self.assertTrue(response["result"].get("isError"), bad_limit)

    def test_search_people_also_honors_limit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)
            for index in range(10):
                profile = root / "Plaud" / "peoples" / f"Roadmap-Person-{index:02d}" / "profile.md"
                profile.parent.mkdir(parents=True)
                profile.write_text(f'---\nname: "Roadmap Person {index:02d}"\n---\n## Notes\nroadmap contributor\n', encoding="utf-8")
            limited = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_people", "arguments": {"keyword": "roadmap", "limit": 3}}})
            payload = json.loads(limited["result"]["content"][0]["text"])
            self.assertEqual(len(payload), 3)

    def test_search_meetings_from_to_filters_an_inclusive_date_range(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = make_store(root)  # "fixture" is createdAt 2026-07-14
            for stem, created_at in (("before-range", "2026-06-30T00:00:00Z"), ("in-range", "2026-07-20T00:00:00Z"), ("after-range", "2026-08-05T00:00:00Z")):
                directory = root / "Plaud" / "recordings" / stem
                directory.mkdir(parents=True)
                directory.joinpath("meeting.json").write_text(
                    json.dumps({"stem": stem, "title": "t", "source": "local", "createdAt": created_at, "stage": "complete"}),
                    encoding="utf-8",
                )
            response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"from": "2026-07-01", "to": "2026-07-31"}}})
            payload = json.loads(response["result"]["content"][0]["text"])
            self.assertEqual({item["stem"] for item in payload}, {"fixture", "in-range"})

            # "to" is inclusive of the entire day given, not just an exact
            # timestamp match - "2026-08-05T00:00:00Z" must be included when
            # `to` is "2026-08-05".
            open_ended = dispatch(store, {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"from": "2026-08-01", "to": "2026-08-05"}}})
            open_payload = json.loads(open_ended["result"]["content"][0]["text"])
            self.assertEqual({item["stem"] for item in open_payload}, {"after-range"})

    def test_search_meetings_rejects_date_combined_with_a_range(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))
            response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "search_meetings", "arguments": {"date": "2026-07", "from": "2026-01"}}})
            self.assertNotIn("error", response)
            self.assertTrue(response["result"]["isError"])

    def test_initialize_carries_server_wide_instructions(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))
            response = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}})
            instructions = response["result"]["instructions"]
            self.assertIsInstance(instructions, str)
            self.assertGreater(len(instructions), 0)
            self.assertIn("stem", instructions)

    def test_every_tool_declares_read_only_and_every_parameter_has_a_description(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = make_store(Path(temporary))
            definitions = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})["result"]["tools"]
            self.assertEqual(len(definitions), 4)
            for tool in definitions:
                self.assertTrue(tool.get("description"), tool["name"])
                self.assertTrue(tool.get("annotations", {}).get("readOnlyHint"), tool["name"])
                properties = tool["inputSchema"].get("properties", {})
                self.assertTrue(properties, tool["name"])
                for param_name, schema in properties.items():
                    self.assertTrue(schema.get("description"), f"{tool['name']}.{param_name}")

    def test_get_meeting_returns_an_empty_transcript_when_none_exists_yet(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record_dir = root / "Plaud" / "recordings" / "not-yet-transcribed"
            record_dir.mkdir(parents=True)
            record_dir.joinpath("meeting.json").write_text(json.dumps({"stem": "not-yet-transcribed", "title": "t", "source": "local", "createdAt": "2026-08-01T00:00:00Z", "stage": "captured"}), encoding="utf-8")
            store = ReadOnlyStore(root)
            meeting = dispatch(store, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "get_meeting", "arguments": {"stem": "not-yet-transcribed"}}})
            payload = json.loads(meeting["result"]["content"][0]["text"])
            self.assertEqual(payload["transcript"], [])


if __name__ == "__main__":
    unittest.main()
