import json
import tempfile
import unittest
from pathlib import Path

from damso.contracts import write_phase_one
from damso.people import read_profile
from damso.serve import PROTOCOL_VERSION, PROTOCOL_VERSION_MISMATCH_CODE, Store, dispatch, handle_line


def make_meeting_record(stem: str, **overrides) -> dict:
    record = {
        "schemaVersion": 1,
        "stem": stem,
        "id": "79613422-B6B0-4566-B7C8-F8CEBD5D87E1",
        "createdAt": "2026-07-14T00:00:00.000Z",
        "source": "local",
        "title": "Synthetic fixture",
        "stage": "captured",
        "completedStages": ["captured"],
        "sensitive": False,
        "hints": {"participants": [], "domainTerms": []},
        "resolutions": [],
    }
    record.update(overrides)
    return record


def make_bare_record(root: Path, stem: str = "fixture") -> Path:
    record = root / "Plaud" / "recordings" / stem
    record.mkdir(parents=True)
    (record / "meeting.json").write_text(json.dumps(make_meeting_record(stem)), encoding="utf-8")
    return record


def record_request(operation: str, **fields) -> dict:
    request = {"protocol_version": PROTOCOL_VERSION, "operation": operation}
    request.update(fields)
    return request


def make_resolvable_record(root: Path) -> Path:
    record = root / "Plaud" / "recordings" / "fixture"
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
    return record


def apply_resolutions_request(record: Path, peoples: Path, **overrides) -> dict:
    request = {
        "protocol_version": PROTOCOL_VERSION,
        "operation": "apply-resolutions",
        "recording_directory": str(record),
        "peoples_directory": str(peoples),
        "meeting_date": "2026-07-14",
        "resolutions": {"SPEAKER_00": {"action": "new", "name": "Kim"}},
    }
    request.update(overrides)
    return request


class ServeDispatchTests(unittest.TestCase):
    def test_known_operation_routes_to_existing_processing_logic(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = make_resolvable_record(root)
            peoples = root / "Plaud" / "peoples"
            store = Store.at(root)

            response = dispatch(store, apply_resolutions_request(record, peoples))

            self.assertEqual(response["ok"], True)
            self.assertEqual(response["stage"], "ready_for_summary")
            self.assertEqual(response["recording_stem"], "fixture")
            fields, _ = read_profile(peoples / "Kim" / "profile.md", "Kim", "2026-07-14")
            self.assertEqual(fields["meeting_count"], 1)
            self.assertTrue(record.joinpath("resolutions.yaml").exists())

    def test_protocol_version_mismatch_is_rejected_before_any_store_mutation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = make_resolvable_record(root)
            peoples = root / "Plaud" / "peoples"
            store = Store.at(root)

            response = dispatch(
                store,
                apply_resolutions_request(record, peoples, protocol_version=PROTOCOL_VERSION + 1, id="req-1"),
            )

            self.assertEqual(response["jsonrpc"], "2.0")
            self.assertEqual(response["id"], "req-1")
            self.assertEqual(response["error"]["code"], PROTOCOL_VERSION_MISMATCH_CODE)
            self.assertFalse(record.joinpath("resolutions.yaml").exists())
            self.assertFalse(peoples.exists())

    def test_unknown_operation_returns_json_rpc_error(self):
        with tempfile.TemporaryDirectory() as temporary:
            store = Store.at(Path(temporary))

            response = dispatch(store, {"protocol_version": PROTOCOL_VERSION, "operation": "delete-everything", "id": 7})

            self.assertEqual(response["jsonrpc"], "2.0")
            self.assertEqual(response["id"], 7)
            self.assertEqual(response["error"]["code"], -32602)

    def test_recording_directory_outside_the_configured_store_is_rejected(self):
        with tempfile.TemporaryDirectory() as store_temp, tempfile.TemporaryDirectory() as other_temp:
            store_root = Path(store_temp)
            outside_root = Path(other_temp)
            record = make_resolvable_record(outside_root)
            peoples = outside_root / "Plaud" / "peoples"
            store = Store.at(store_root)

            response = dispatch(store, apply_resolutions_request(record, peoples))

            self.assertEqual(response["ok"], False)
            self.assertIn("code", response["error"])
            self.assertFalse(record.joinpath("resolutions.yaml").exists())

    def test_set_person_email_does_not_require_a_recording_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            peoples = root / "Plaud" / "peoples"
            peoples.mkdir(parents=True)
            store = Store.at(root)

            response = dispatch(
                store,
                {
                    "protocol_version": PROTOCOL_VERSION,
                    "operation": "set-person-email",
                    "peoples_directory": str(peoples),
                    "name": "Kim",
                    "email": "kim@example.com",
                },
            )

            self.assertEqual(response["ok"], True)
            fields, _ = read_profile(peoples / "Kim" / "profile.md", "Kim", "2026-07-14")
            self.assertEqual(fields["email"], "kim@example.com")


class RecordOperationTests(unittest.TestCase):
    def test_update_record_replaces_meeting_json_atomically(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = make_bare_record(root)
            store = Store.at(root)
            updated = make_meeting_record("fixture", stage="speakerReview", title="Renamed")

            response = dispatch(store, record_request("update-record", recording_directory=str(record), record=updated))

            self.assertEqual(response["ok"], True)
            on_disk = json.loads((record / "meeting.json").read_text(encoding="utf-8"))
            self.assertEqual(on_disk["stage"], "speakerReview")
            self.assertEqual(on_disk["title"], "Renamed")

    def test_update_record_rejects_a_stem_mismatch_without_writing_anything(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = make_bare_record(root)
            store = Store.at(root)
            before = (record / "meeting.json").read_text(encoding="utf-8")
            wrong_stem_record = make_meeting_record("some-other-stem")

            response = dispatch(store, record_request("update-record", recording_directory=str(record), record=wrong_stem_record))

            self.assertEqual(response["ok"], False)
            self.assertEqual((record / "meeting.json").read_text(encoding="utf-8"), before)

    def test_delete_record_removes_the_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = make_bare_record(root)
            store = Store.at(root)

            response = dispatch(store, record_request("delete-record", recording_directory=str(record)))

            self.assertEqual(response["ok"], True)
            self.assertFalse(record.exists())

    def test_delete_record_is_idempotent_for_an_already_deleted_directory(self):
        """The client's mirror can lag the server: a delete that succeeded
        server-side while the client's own follow-up failed leaves the client
        re-sending the delete for a directory that no longer exists. That
        retry must succeed - a real two-machine run showed the error branch
        made the meeting permanently undeletable, since the stale local copy
        kept resurfacing it while every retry failed on resolve()."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = make_bare_record(root)
            store = Store.at(root)

            first = dispatch(store, record_request("delete-record", recording_directory=str(record)))
            self.assertEqual(first["ok"], True)
            second = dispatch(store, record_request("delete-record", recording_directory=str(record)))
            self.assertEqual(second["ok"], True)

    def test_delete_record_still_rejects_a_malformed_path_even_when_absent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            store = Store.at(root)

            outside = dispatch(store, record_request("delete-record", recording_directory=str(root / "elsewhere" / "fixture")))
            self.assertEqual(outside["ok"], False)

            traversal = dispatch(store, record_request("delete-record", recording_directory=str(root / "Plaud" / "recordings" / "..")))
            self.assertEqual(traversal["ok"], False)

    def test_quarantine_record_moves_the_directory_and_writes_the_reason(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = make_bare_record(root)
            store = Store.at(root)

            response = dispatch(store, record_request("quarantine-record", recording_directory=str(record), reason="recording_start_failed"))

            self.assertEqual(response["ok"], True)
            self.assertFalse(record.exists())
            quarantined = list((root / ".quarantine").iterdir())
            self.assertEqual(len(quarantined), 1)
            self.assertTrue(quarantined[0].name.startswith("fixture-"))
            self.assertEqual((quarantined[0] / "reason.txt").read_text(encoding="utf-8"), "recording_start_failed")

    def test_invalidate_phase_one_dependents_removes_only_the_fixed_allowlist(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = make_bare_record(root)
            store = Store.at(root)
            (record / "resolutions.yaml").write_text("stale", encoding="utf-8")
            (record / "transcript.raw.json").write_text('{"kept": true}', encoding="utf-8")

            response = dispatch(store, record_request("invalidate-phase-one-dependents", recording_directory=str(record)))

            self.assertEqual(response["ok"], True)
            self.assertFalse((record / "resolutions.yaml").exists())
            self.assertTrue((record / "transcript.raw.json").exists())

    def test_invalidate_cleanup_overlay_removes_only_the_overlay(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            record = make_bare_record(root)
            store = Store.at(root)
            (record / "transcript.cleaned.json").write_text("stale", encoding="utf-8")
            (record / "transcript.raw.json").write_text('{"kept": true}', encoding="utf-8")

            response = dispatch(store, record_request("invalidate-cleanup-overlay", recording_directory=str(record)))

            self.assertEqual(response["ok"], True)
            self.assertFalse((record / "transcript.cleaned.json").exists())
            self.assertTrue((record / "transcript.raw.json").exists())

    def test_commit_record_promotes_a_validated_staging_directory_atomically(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            staging_parent = root / ".staging"
            staging_parent.mkdir(parents=True)
            staging_directory = staging_parent / "incoming-uuid"
            staging_directory.mkdir()
            (staging_directory / "meeting.json").write_text(json.dumps(make_meeting_record("new-recording")), encoding="utf-8")
            (staging_directory / "audio.ogg").write_bytes(b"synthetic audio")
            target = root / "Plaud" / "recordings" / "new-recording"
            store = Store.at(root)

            response = dispatch(store, record_request("commit-record", staging_directory=str(staging_directory), recording_directory=str(target)))

            self.assertEqual(response["ok"], True)
            self.assertTrue((target / "meeting.json").exists())
            self.assertTrue((target / "audio.ogg").exists())
            self.assertFalse(staging_directory.exists())

    def test_commit_record_refuses_to_overwrite_an_existing_canonical_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            existing = make_bare_record(root, stem="fixture")
            staging_parent = root / ".staging"
            staging_parent.mkdir(parents=True)
            staging_directory = staging_parent / "incoming-uuid"
            staging_directory.mkdir()
            (staging_directory / "meeting.json").write_text(json.dumps(make_meeting_record("fixture")), encoding="utf-8")
            store = Store.at(root)

            response = dispatch(store, record_request("commit-record", staging_directory=str(staging_directory), recording_directory=str(existing)))

            self.assertEqual(response["ok"], False)
            self.assertTrue(staging_directory.exists())

    def test_commit_record_rejects_a_staging_directory_outside_the_store(self):
        with tempfile.TemporaryDirectory() as store_temp, tempfile.TemporaryDirectory() as outside_temp:
            root = Path(store_temp)
            outside_staging = Path(outside_temp) / "incoming-uuid"
            outside_staging.mkdir()
            (outside_staging / "meeting.json").write_text(json.dumps(make_meeting_record("new-recording")), encoding="utf-8")
            target = root / "Plaud" / "recordings" / "new-recording"
            store = Store.at(root)

            response = dispatch(store, record_request("commit-record", staging_directory=str(outside_staging), recording_directory=str(target)))

            self.assertEqual(response["ok"], False)
            self.assertTrue(outside_staging.exists())


def make_profile(peoples: Path, name: str, **fields) -> Path:
    from damso.people import slugify, write_profile

    directory = peoples / slugify(name)
    base = {"name": name, "aliases": [], "first_seen": "2026-01-01", "last_seen": "2026-01-01", "meeting_count": 0}
    base.update(fields)
    write_profile(directory / "profile.md", base, "## Description\n\n## Meetings\n\n## Notes\n")
    return directory


class PeopleOperationTests(unittest.TestCase):
    def test_delete_person_archives_the_profile_and_denylists_the_name(self):
        from damso.people import read_profile

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            peoples = root / "Plaud" / "peoples"
            make_profile(peoples, "Kim")
            store = Store.at(root)

            response = dispatch(store, record_request("delete-person", peoples_directory=str(peoples), name="Kim", aliases=["김철수"]))

            self.assertEqual(response["ok"], True)
            self.assertFalse((peoples / "Kim" / "profile.md").exists())
            archived = list((peoples / "archive").iterdir())
            self.assertEqual(len(archived), 1)
            deleted = json.loads((peoples / ".deleted-people.json").read_text(encoding="utf-8"))
            self.assertIn("Kim", deleted)
            self.assertIn("김철수", deleted)

    def test_unmark_person_deleted_removes_only_the_matching_entry(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            peoples = root / "Plaud" / "peoples"
            peoples.mkdir(parents=True)
            (peoples / ".deleted-people.json").write_text(json.dumps(["Kim", "Park"]), encoding="utf-8")
            store = Store.at(root)

            response = dispatch(store, record_request("unmark-person-deleted", peoples_directory=str(peoples), name="Kim"))

            self.assertEqual(response["ok"], True)
            remaining = json.loads((peoples / ".deleted-people.json").read_text(encoding="utf-8"))
            self.assertEqual(remaining, ["Park"])

    def test_merge_profiles_transfers_history_voice_and_notes_into_the_primary(self):
        from damso.people import read_profile

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            peoples = root / "Plaud" / "peoples"
            make_profile(
                peoples, "Kim",
                meeting_stems=["fixture-1"], meeting_count=1, first_seen="2026-02-01", last_seen="2026-02-01",
            )
            absorbed = make_profile(
                peoples, "Kim2",
                meeting_stems=["fixture-2"], meeting_count=1, first_seen="2026-01-01", last_seen="2026-03-01",
                email="kim@example.com",
            )
            (absorbed / "profile.md").write_text(
                (absorbed / "profile.md").read_text(encoding="utf-8").replace("## Notes\n", "## Notes\nInterested in the roadmap.\n"),
                encoding="utf-8",
            )
            (absorbed / "voice.npy").write_bytes(b"synthetic-embedding")
            store = Store.at(root)

            response = dispatch(store, record_request("merge-profiles", peoples_directory=str(peoples), primary_name="Kim", absorbed_name="Kim2"))

            self.assertEqual(response["ok"], True)
            self.assertFalse(absorbed.exists())
            fields, body = read_profile(peoples / "Kim" / "profile.md", "Kim", "2026-01-01")
            self.assertIn("Kim2", fields["aliases"])
            self.assertEqual(sorted(fields["meeting_stems"]), ["fixture-1", "fixture-2"])
            self.assertEqual(fields["first_seen"], "2026-01-01")
            self.assertEqual(fields["last_seen"], "2026-03-01")
            self.assertEqual(fields["email"], "kim@example.com")
            self.assertTrue((peoples / "Kim" / "voice.npy").exists())
            self.assertIn("Interested in the roadmap. [Kim2]", body)
            archived = list((peoples / "archive").iterdir())
            self.assertEqual(len(archived), 1)
            self.assertTrue((archived[0] / "profile.md").exists())

    def test_merge_profiles_rejects_merging_a_profile_into_itself(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            peoples = root / "Plaud" / "peoples"
            make_profile(peoples, "Kim")
            store = Store.at(root)

            response = dispatch(store, record_request("merge-profiles", peoples_directory=str(peoples), primary_name="Kim", absorbed_name="Kim"))

            self.assertEqual(response["ok"], False)


class ServeLineHandlingTests(unittest.TestCase):
    def test_blank_line_produces_no_response(self):
        store = Store.at(Path(tempfile.gettempdir()))
        self.assertIsNone(handle_line(store, "\n"))

    def test_malformed_json_line_returns_parse_error_envelope(self):
        store = Store.at(Path(tempfile.gettempdir()))

        response = handle_line(store, "{not json")

        self.assertEqual(response, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}})

    def test_non_object_json_line_returns_parse_error_envelope(self):
        store = Store.at(Path(tempfile.gettempdir()))

        response = handle_line(store, json.dumps([1, 2, 3]))

        self.assertEqual(response["error"]["code"], -32700)


if __name__ == "__main__":
    unittest.main()
