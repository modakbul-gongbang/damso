import tempfile
import unittest
from pathlib import Path

from damso.people import apply_people_resolutions, read_profile, slugify


class PeopleTests(unittest.TestCase):
    def test_machine_fields_update_without_rewriting_notes(self):
        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            profile = peoples / "Kim" / "profile.md"
            profile.parent.mkdir(parents=True)
            profile.write_text("---\nname: \"Kim\"\nmeeting_count: 1\nvoice_samples: 0\n---\n## Notes\nDo not change this.\n", encoding="utf-8")
            apply_people_resolutions(peoples, {"SPEAKER_00": {"action": "match", "name": "Kim"}}, "2026-07-14")
            fields, body = read_profile(profile, "Kim", "2026-07-14")
            self.assertEqual(fields["meeting_count"], 2)
            self.assertIn("Do not change this.", body)

    def test_name_only_resolution_never_creates_a_profile(self):
        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            apply_people_resolutions(peoples, {"SPEAKER_00": {"action": "name_only", "name": "게스트"}}, "2026-07-17")
            self.assertFalse(peoples.exists())

    def test_slug_is_safe_for_local_profile_directory(self):
        self.assertEqual(slugify(" Kim / Partner "), "Kim-_-Partner")

    def test_owner_profile_stays_outside_the_people_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            plaud = Path(temporary) / "Plaud"
            apply_people_resolutions(plaud / "peoples", {"SPEAKER_00": {"action": "me", "name": "Owner"}}, "2026-07-14")
            self.assertTrue(plaud.joinpath("me", "profile.md").is_file())
            self.assertFalse(plaud.joinpath("peoples", "me", "profile.md").exists())

    def test_reapplying_the_same_meeting_stem_does_not_increment_profile_count(self):
        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            resolutions = {"SPEAKER_00": {"action": "new", "name": "Kim"}}
            apply_people_resolutions(peoples, resolutions, "2026-07-14", meeting_stem="fixture")
            apply_people_resolutions(peoples, resolutions, "2026-07-14", meeting_stem="fixture")

            fields, _ = read_profile(peoples / "Kim" / "profile.md", "Kim", "2026-07-14")
            self.assertEqual(fields["meeting_count"], 1)
            self.assertEqual(fields["meeting_stems"], ["fixture"])


class PersonNoteTests(unittest.TestCase):
    def test_accepted_note_is_appended_under_notes_without_touching_other_sections(self):
        from damso.people import append_person_note

        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            profile = peoples / "Kim" / "profile.md"
            profile.parent.mkdir(parents=True)
            profile.write_text(
                "---\nname: \"Kim\"\nmeeting_count: 1\n---\n## Description\nKeep this.\n\n## Notes\n- (2026-07-01) Existing note.\n",
                encoding="utf-8",
            )
            append_person_note(peoples, "Kim", "Owns the launch checklist.", "2026-07-14")
            fields, body = read_profile(profile, "Kim", "2026-07-14")
            self.assertEqual(fields["meeting_count"], 1)
            self.assertIn("Keep this.", body)
            self.assertIn("- (2026-07-01) Existing note.", body)
            self.assertIn("- (2026-07-14) Owns the launch checklist.", body)
            self.assertLess(body.index("Existing note."), body.index("Owns the launch checklist."))

    def test_note_for_a_new_person_creates_a_profile_with_a_notes_section(self):
        from damso.people import append_person_note

        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            append_person_note(peoples, "Lee", "Prefers async updates.", "2026-07-14")
            fields, body = read_profile(peoples / "Lee" / "profile.md", "Lee", "2026-07-14")
            self.assertEqual(fields["name"], "Lee")
            self.assertIn("- (2026-07-14) Prefers async updates.", body)

    def test_empty_note_is_rejected(self):
        from damso.people import append_person_note

        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            with self.assertRaises(ValueError):
                append_person_note(peoples, "Kim", "   ")


class CandidateThresholdTests(unittest.TestCase):
    def test_noise_level_candidates_are_filtered_and_sorted(self):
        import numpy as np
        from damso.people import compatible_voice_candidates, write_voice_embedding, write_profile

        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            query = np.zeros(8, dtype=np.float32); query[0] = 1.0
            vectors = {
                "강한후보": [0.9, 0.1, 0, 0, 0, 0, 0, 0],
                "중간후보": [0.5, 0.5, 0.5, 0, 0, 0, 0, 0],
                "노이즈후보": [-0.5, 0.5, 0.5, 0.5, 0, 0, 0, 0],
            }
            for name, vector in vectors.items():
                directory = peoples / name
                directory.mkdir(parents=True)
                write_profile(directory / "profile.md", {"name": name, "voice_model": "sherpa-onnx/3dspeaker-speech-eres2net-base-sv-zh-cn-3dspeaker-16k"}, "## Notes\n")
                write_voice_embedding(directory / "voice.npy", vector)

            candidates = compatible_voice_candidates(peoples, query.tolist())

            names = [candidate.name for candidate in candidates]
            self.assertEqual(names, ["강한후보", "중간후보"])
            self.assertGreater(candidates[0].voice_score, candidates[1].voice_score)
            self.assertTrue(all(candidate.voice_score >= 0.25 for candidate in candidates))


class PersonEmailTests(unittest.TestCase):
    def test_email_is_set_updated_and_cleared(self):
        from damso.people import set_person_email

        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            profile = peoples / "Kim" / "profile.md"
            profile.parent.mkdir(parents=True)
            profile.write_text('---\nname: "Kim"\n---\n## Notes\nKeep this.\n', encoding="utf-8")

            set_person_email(peoples, "Kim", "kim@example.com")
            fields, body = read_profile(profile, "Kim", "2026-07-16")
            self.assertEqual(fields["email"], "kim@example.com")
            self.assertIn("Keep this.", body)

            set_person_email(peoples, "Kim", "")
            fields, _ = read_profile(profile, "Kim", "2026-07-16")
            self.assertNotIn("email", fields)

    def test_invalid_email_is_rejected(self):
        from damso.people import set_person_email

        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            peoples.mkdir(parents=True)
            with self.assertRaises(ValueError):
                set_person_email(peoples, "Kim", "not an email")


class PersonAliasTests(unittest.TestCase):
    def test_confirmation_alias_accumulates_with_exact_match_dedup(self):
        from damso.people import remove_person_alias

        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            resolutions = {"SPEAKER_00": {"action": "new", "name": "김가상", "alias": "김가상 (Kasang)"}}
            apply_people_resolutions(peoples, resolutions, "2026-07-16", meeting_stem="fixture-a")
            # The same alias again does not duplicate; a new one appends.
            apply_people_resolutions(peoples, resolutions, "2026-07-16", meeting_stem="fixture-b")
            apply_people_resolutions(
                peoples,
                {"SPEAKER_00": {"action": "match", "name": "김가상", "alias": "Kasang Kim"}},
                "2026-07-16",
                meeting_stem="fixture-c",
            )

            profile = peoples / "김가상" / "profile.md"
            fields, _ = read_profile(profile, "김가상", "2026-07-16")
            self.assertEqual(fields["aliases"], ["김가상 (Kasang)", "Kasang Kim"])

            remove_person_alias(peoples, "김가상", "김가상 (Kasang)")
            fields, _ = read_profile(profile, "김가상", "2026-07-16")
            self.assertEqual(fields["aliases"], ["Kasang Kim"])

    def test_primary_name_never_becomes_its_own_alias(self):
        with tempfile.TemporaryDirectory() as temporary:
            peoples = Path(temporary) / "Plaud" / "peoples"
            apply_people_resolutions(
                peoples,
                {"SPEAKER_00": {"action": "new", "name": "김가상", "alias": "김가상"}},
                "2026-07-16",
                meeting_stem="fixture",
            )
            fields, _ = read_profile(peoples / "김가상" / "profile.md", "김가상", "2026-07-16")
            self.assertEqual(fields.get("aliases", []), [])
