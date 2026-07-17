import tempfile
import unittest
from pathlib import Path

from damso.migration import create_backup, directory_checksum, migrate_copy, preview_copy, relocate_copy, restore_backup, run_storage_action


def write_store_manifest(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    root.joinpath("store.json").write_text('{"schemaVersion": 1}', encoding="utf-8")


class MigrationTests(unittest.TestCase):
    def test_copy_is_non_destructive_idempotent_and_reports_collisions(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, target = base / "source", base / "target"
            recording = source / "Plaud" / "recordings" / "meeting-a"
            person = source / "Plaud" / "peoples" / "kim"
            recording.mkdir(parents=True)
            person.mkdir(parents=True)
            recording.joinpath("meeting.json").write_text('{"stem":"meeting-a"}', encoding="utf-8")
            person.joinpath("profile.md").write_text("# Kim\n", encoding="utf-8")
            original = directory_checksum(recording)

            preview = preview_copy(source, target)
            self.assertEqual({item.action for item in preview.items}, {"copy"})
            first = migrate_copy(source, target)
            self.assertEqual(first.copied, 2)
            self.assertEqual(directory_checksum(recording), original)
            second = migrate_copy(source, target)
            self.assertEqual(second.skipped, 2)

            target.joinpath("Plaud", "recordings", "meeting-a", "meeting.json").write_text('{"changed":true}', encoding="utf-8")
            collision = preview_copy(source, target)
            self.assertEqual(collision.collisions, 1)

    def test_backup_and_restore_preserve_canonical_checksums(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, backup, restored = base / "source", base / "backup", base / "restored"
            write_store_manifest(source)
            record = source / "Plaud" / "recordings" / "fixture"
            person = source / "Plaud" / "peoples" / "kim"
            record.mkdir(parents=True)
            person.mkdir(parents=True)
            record.joinpath("meeting.json").write_text('{"stem":"fixture"}', encoding="utf-8")
            person.joinpath("voice.npy").write_bytes(b"synthetic-voice")
            create_backup(source, backup)
            result = restore_backup(backup, restored)
            self.assertEqual(result.copied, 2)
            self.assertEqual(directory_checksum(record), directory_checksum(restored / "Plaud" / "recordings" / "fixture"))
            self.assertEqual(directory_checksum(person), directory_checksum(restored / "Plaud" / "peoples" / "kim"))
            self.assertEqual(restored.joinpath("store.json").read_text(encoding="utf-8"), '{"schemaVersion": 1}')

    def test_backup_corruption_is_rejected_and_relocation_keeps_source_intact(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, backup, restored, relocated = base / "source", base / "backup", base / "restored", base / "relocated"
            write_store_manifest(source)
            record = source / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            record.joinpath("meeting.json").write_text('{"stem":"fixture"}', encoding="utf-8")
            original = directory_checksum(record)

            create_backup(source, backup)
            backup.joinpath("Plaud", "recordings", "fixture", "meeting.json").write_text('{"tampered":true}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "checksum"):
                restore_backup(backup, restored)
            self.assertFalse(restored.exists())

            result = relocate_copy(source, relocated)
            self.assertEqual(result.copied, 1)
            self.assertEqual(directory_checksum(record), original)
            self.assertEqual(directory_checksum(relocated / "Plaud" / "recordings" / "fixture"), original)
            self.assertEqual(relocated.joinpath("store.json").read_text(encoding="utf-8"), '{"schemaVersion": 1}')

    def test_storage_actions_require_preview_then_explicit_confirmation_for_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source, target = base / "source", base / "target"
            record = source / "Plaud" / "recordings" / "fixture"
            record.mkdir(parents=True)
            record.joinpath("meeting.json").write_text('{"stem":"fixture"}', encoding="utf-8")

            preview = run_storage_action("preview-copy", source, target)
            self.assertEqual(preview.items[0].action, "copy")
            with self.assertRaisesRegex(ValueError, "--confirm"):
                run_storage_action("migrate-copy", source, target)
            result = run_storage_action("migrate-copy", source, target, confirmed=True)
            self.assertEqual(result.copied, 1)
