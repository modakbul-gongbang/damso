"""Non-destructive canonical-store migration, backup, and relocation helpers."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import tempfile
import argparse
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


STORE_MANIFEST = "store.json"
BACKUP_MANIFEST = "damso-backup-manifest.json"


@dataclass(frozen=True)
class MigrationItem:
    section: str
    name: str
    action: str
    checksum: str | None


@dataclass(frozen=True)
class MigrationReport:
    copied: int
    skipped: int
    collisions: int
    failed: int
    items: tuple[MigrationItem, ...]


def canonical_paths(root: Path) -> dict[str, Path]:
    return {"recordings": root / "Plaud" / "recordings", "peoples": root / "Plaud" / "peoples"}


def store_schema_version(root: Path) -> int:
    """Read the schema owned by the canonical store without exposing its path."""
    manifest = root / STORE_MANIFEST
    try:
        value = json.loads(manifest.read_text(encoding="utf-8"))
        version = value["schemaVersion"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise ValueError("a readable canonical store manifest is required") from error
    if not isinstance(version, int) or version < 1:
        raise ValueError("canonical store schema version is invalid")
    return version


def preview_copy(source_root: Path, target_root: Path) -> MigrationReport:
    items: list[MigrationItem] = []
    for section, source in canonical_paths(source_root).items():
        target = canonical_paths(target_root)[section]
        for directory in sorted_directories(source):
            checksum = directory_checksum(directory)
            target_directory = target / directory.name
            if not target_directory.exists():
                items.append(MigrationItem(section, directory.name, "copy", checksum))
            elif target_directory.is_dir() and directory_checksum(target_directory) == checksum:
                items.append(MigrationItem(section, directory.name, "skip_identical", checksum))
            else:
                items.append(MigrationItem(section, directory.name, "collision", checksum))
    return report(items)


def migrate_copy(source_root: Path, target_root: Path) -> MigrationReport:
    preview = preview_copy(source_root, target_root)
    paths = canonical_paths(target_root)
    for path in paths.values():
        path.mkdir(parents=True, exist_ok=True)
    staged: list[tuple[MigrationItem, Path]] = []
    items: list[MigrationItem] = []
    with tempfile.TemporaryDirectory(prefix="damso-migration-", dir=target_root) as staging:
        staging_root = Path(staging)
        for item in preview.items:
            if item.action != "copy":
                items.append(item)
                continue
            source = canonical_paths(source_root)[item.section] / item.name
            if directory_checksum(source) != item.checksum:
                items.append(MigrationItem(item.section, item.name, "failed_source_changed", item.checksum))
                continue
            temporary_target = staging_root / item.section / item.name
            try:
                temporary_target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copytree(source, temporary_target)
                if directory_checksum(temporary_target) != item.checksum:
                    items.append(MigrationItem(item.section, item.name, "failed_checksum", item.checksum))
                    continue
                staged.append((item, temporary_target))
            except OSError:
                items.append(MigrationItem(item.section, item.name, "failed_copy", item.checksum))
        for item, temporary_target in staged:
            destination = paths[item.section] / item.name
            if destination.exists():
                items.append(MigrationItem(item.section, item.name, "collision", item.checksum))
                continue
            try:
                os.replace(temporary_target, destination)
                items.append(MigrationItem(item.section, item.name, "copied", item.checksum))
            except OSError:
                items.append(MigrationItem(item.section, item.name, "failed_commit", item.checksum))
    return report(items)


def create_backup(source_root: Path, backup_root: Path) -> MigrationReport:
    """Copy a schema-aware canonical store and record non-sensitive checksums."""
    schema_version = store_schema_version(source_root)
    result = migrate_copy(source_root, backup_root)
    copy_store_manifest(source_root, backup_root)
    paths = canonical_paths(source_root)
    manifest = {
        "schema_version": schema_version,
        "recording_count": count_directories(paths["recordings"]),
        "people_count": count_directories(paths["peoples"]),
        "items": [asdict(item) for item in result.items],
    }
    temporary = backup_root / ".damso-backup-manifest.tmp"
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, backup_root / BACKUP_MANIFEST)
    return result


def restore_backup(backup_root: Path, target_root: Path) -> MigrationReport:
    verify_backup(backup_root)
    result = migrate_copy(backup_root, target_root)
    copy_store_manifest(backup_root, target_root)
    return result


def relocate_copy(source_root: Path, target_root: Path) -> MigrationReport:
    """Perform an explicit, non-destructive canonical-root relocation copy."""
    store_schema_version(source_root)
    result = migrate_copy(source_root, target_root)
    copy_store_manifest(source_root, target_root)
    return result


def verify_backup(backup_root: Path) -> dict[str, object]:
    manifest_path = backup_root / BACKUP_MANIFEST
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise ValueError("backup manifest is required before restore") from error
    if manifest.get("schema_version") != store_schema_version(backup_root):
        raise ValueError("backup schema does not match its manifest")
    paths = canonical_paths(backup_root)
    if manifest.get("recording_count") != count_directories(paths["recordings"]):
        raise ValueError("backup recording count does not match its manifest")
    if manifest.get("people_count") != count_directories(paths["peoples"]):
        raise ValueError("backup people count does not match its manifest")
    for item in manifest.get("items", []):
        if item.get("action") != "copied":
            continue
        section, name, checksum = item.get("section"), item.get("name"), item.get("checksum")
        if section not in paths or not isinstance(name, str) or not isinstance(checksum, str):
            raise ValueError("backup item manifest is invalid")
        directory = paths[section] / name
        if not directory.is_dir() or directory_checksum(directory) != checksum:
            raise ValueError("backup checksum does not match its manifest")
    return manifest


def directory_checksum(directory: Path) -> str:
    digest = hashlib.sha256()
    for path in sorted(path for path in directory.rglob("*") if path.is_file()):
        digest.update(path.relative_to(directory).as_posix().encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def sorted_directories(path: Path) -> Iterable[Path]:
    if not path.is_dir():
        return []
    return (entry for entry in sorted(path.iterdir()) if entry.is_dir() and not entry.name.startswith("."))


def count_directories(path: Path) -> int:
    return sum(1 for _ in sorted_directories(path))


def copy_store_manifest(source_root: Path, target_root: Path) -> None:
    source = source_root / STORE_MANIFEST
    target = target_root / STORE_MANIFEST
    data = source.read_bytes()
    if target.exists():
        if target.read_bytes() != data:
            raise ValueError("target canonical store manifest conflicts with the source")
        return
    target_root.mkdir(parents=True, exist_ok=True)
    temporary = target_root / ".damso-store-manifest.tmp"
    temporary.write_bytes(data)
    os.replace(temporary, target)


def run_storage_action(action: str, source_root: Path, target_root: Path, confirmed: bool = False) -> MigrationReport:
    """Expose preview-first storage actions without accepting arbitrary paths."""
    if action == "preview-copy":
        return preview_copy(source_root, target_root)
    if not confirmed:
        raise ValueError("use --confirm after reviewing preview-copy before changing a canonical store")
    actions = {
        "migrate-copy": migrate_copy,
        "backup": create_backup,
        "restore": restore_backup,
        "relocate-copy": relocate_copy,
    }
    try:
        return actions[action](source_root, target_root)
    except KeyError as error:
        raise ValueError("unsupported storage action") from error


def main() -> int:
    parser = argparse.ArgumentParser(description="Meeting Hub schema-aware local storage actions")
    parser.add_argument("action", choices=["preview-copy", "migrate-copy", "backup", "restore", "relocate-copy"])
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--target", type=Path, required=True)
    parser.add_argument("--confirm", action="store_true", help="Confirm a non-preview local storage action after reviewing preview-copy")
    args = parser.parse_args()
    try:
        result = run_storage_action(args.action, args.source, args.target, confirmed=args.confirm)
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps({"copied": result.copied, "skipped": result.skipped, "collisions": result.collisions, "failed": result.failed, "items": [asdict(item) for item in result.items]}, ensure_ascii=False, sort_keys=True))
    return 0 if result.failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())


def report(items: Iterable[MigrationItem]) -> MigrationReport:
    result = tuple(items)
    return MigrationReport(
        copied=sum(item.action == "copied" for item in result),
        skipped=sum(item.action == "skip_identical" for item in result),
        collisions=sum(item.action == "collision" for item in result),
        failed=sum(item.action.startswith("failed") for item in result),
        items=result,
    )
