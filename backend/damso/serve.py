"""Stdio line-JSON server for the canonical store's write-side operations.

Runs on the machine that owns the canonical store (the always-on Mac mini) and
is reached over SSH stdio from the client Mac, the same shape as ``mcp.py``'s
read-only tunnel. Requests route to one of two places:

- The seven `processing.py` operations (`phase-one`, `recluster`, ...) go
  straight to the existing `damso.processing` boundary; this module never
  reimplements that logic, it only adds protocol negotiation and store-path
  validation in front of it.
- The six `meeting.json` record operations (`update-record`, `delete-record`,
  ...) are new here, because no Python code owned that file before the store
  could live on a different machine than the Swift app. Each one is a direct
  port of an existing, already-shipped `MeetingStore` Swift method's
  contract - see `execute_record_operation`.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import shutil
import sys
import unicodedata
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from . import processing
from .contracts import atomic_write_json, atomic_write_text, ensure_safe_stem, ContractError
from .people import read_profile, slugify, write_profile

# Bump this when a request or response field changes shape in a way the other
# side must understand before it can process the request correctly. A client
# and server running mismatched versions refuse the operation instead of
# risking a store write neither side fully agrees on the meaning of.
PROTOCOL_VERSION = 1

PROCESSING_OPERATIONS = frozenset(
    {
        "phase-one",
        "recluster",
        "apply-resolutions",
        "refresh-candidates",
        "set-person-email",
        "remove-person-alias",
        "append-person-note",
    }
)

# meeting.json is a full-record replace: the Swift MeetingRecord model is the
# schema owner, so this module treats the record body as an opaque JSON
# object and only checks the two fields Swift's own MeetingStore.update()
# already validates before an atomic write.
RECORD_SCHEMA_VERSION = 1

# Removing these mirrors MeetingStore.invalidatePhaseOneDependents(): only the
# generated outputs whose meaning depends on the previous phase-one speaker
# labels. Raw audio, raw transcript evidence, and unrelated metadata are
# deliberately outside this fixed allowlist.
PHASE_ONE_DEPENDENT_ARTIFACTS = (
    "resolutions.yaml",
    "transcript.json",
    "summary.json",
    "transcript.cleaned.json",
    "speaker_hints.json",
    "transcript.md",
)

# Mirrors MeetingStore.invalidateCleanupOverlay(): recluster keeps its raw
# evidence but the index-keyed cleanup overlay no longer matches it.
CLEANUP_OVERLAY_ARTIFACTS = ("transcript.cleaned.json",)

RECORD_OPERATIONS = frozenset(
    {
        "update-record",
        "delete-record",
        "quarantine-record",
        "invalidate-phase-one-dependents",
        "invalidate-cleanup-overlay",
        "commit-record",
    }
)

# Thin ports of the Swift `MeetingStore` people-management extensions
# (ProfileMerge.swift, ProfileDelete.swift) - same rationale as
# RECORD_OPERATIONS: these mutate the canonical peoples directory and had no
# Python counterpart before the store could live on a different machine.
PEOPLE_OPERATIONS = frozenset(
    {
        "delete-person",
        "unmark-person-deleted",
        "merge-profiles",
    }
)

KNOWN_OPERATIONS = PROCESSING_OPERATIONS | RECORD_OPERATIONS | PEOPLE_OPERATIONS

# JSON-RPC reserves -32000..-32099 for implementation-defined server errors.
# This code is a stable, client-matchable identifier: the Mac app checks for
# exactly this value to show "Update Damso on the Mac mini" instead of a
# generic failure, so it must never be reused for another error condition.
PROTOCOL_VERSION_MISMATCH_CODE = -32001


@dataclass(frozen=True)
class Store:
    root: Path

    @classmethod
    def at(cls, root: Path) -> "Store":
        return cls(root.expanduser().resolve())


def dispatch(store: Store, request: Mapping[str, Any]) -> dict[str, Any]:
    request_id = request.get("id")
    protocol_version = request.get("protocol_version")
    if protocol_version != PROTOCOL_VERSION:
        return rpc_error(
            request_id,
            PROTOCOL_VERSION_MISMATCH_CODE,
            f"unsupported protocol_version {protocol_version!r}; server requires {PROTOCOL_VERSION}",
        )
    operation = request.get("operation")
    if operation not in KNOWN_OPERATIONS:
        return rpc_error(request_id, -32602, f"unknown operation: {operation!r}")
    try:
        require_request_paths_inside_store(store, request)
        if operation in RECORD_OPERATIONS:
            result = execute_record_operation(operation, request)
        elif operation in PEOPLE_OPERATIONS:
            result = execute_people_operation(operation, request)
        else:
            result = processing.execute_request(request)
    except processing.ProcessingTerminated:
        raise
    except Exception as error:  # noqa: BLE001 - mirrored from processing.main()'s own boundary
        return {"ok": False, "error": processing.public_error(error)}
    return result


def require_request_paths_inside_store(store: Store, request: Mapping[str, Any]) -> None:
    for field in ("recording_directory", "peoples_directory", "staging_directory"):
        raw_value = request.get(field)
        if not isinstance(raw_value, str) or not raw_value:
            continue
        candidate = Path(raw_value).expanduser()
        try:
            resolved = candidate.resolve(strict=False)
        except OSError as error:
            raise processing.ProcessingError(f"{field} could not be resolved") from error
        if resolved != store.root and store.root not in resolved.parents:
            raise processing.ProcessingError(f"{field} must be inside the configured store")


def execute_record_operation(operation: str, request: Mapping[str, Any]) -> dict[str, Any]:
    """The `meeting.json` record boundary (D-C1): thin ports of the Swift
    `MeetingStore` methods of the same shape, now needed server-side because
    the canonical store no longer lives where the Swift app runs. Every
    method here mirrors an existing, already-shipped Swift method's contract
    exactly; none introduces new policy.
    """
    if operation == "update-record":
        recording_directory = existing_recording_directory(request.get("recording_directory"))
        record = request.get("record")
        validate_record_body(record, expected_stem=recording_directory.name)
        atomic_write_json(recording_directory / "meeting.json", record)
        return {"ok": True, "operation": operation, "recording_stem": recording_directory.name}

    if operation == "delete-record":
        # Idempotent by contract: the desired end state is "this recording is
        # gone", and the client's mirror can legitimately lag the server (a
        # delete that succeeded server-side while the client's own follow-up
        # failed leaves the client re-sending the delete for a directory that
        # no longer exists - confirmed via a real two-machine run, where that
        # exact sequence made a meeting undeletable: every retry failed on
        # resolve() while the local copy kept resurrecting it in the UI).
        # The path is still fully validated; only the existence requirement
        # is relaxed.
        recording_directory = deletable_recording_directory(request.get("recording_directory"))
        if recording_directory.exists():
            shutil.rmtree(recording_directory)
        return {"ok": True, "operation": operation}

    if operation == "quarantine-record":
        recording_directory = existing_recording_directory(request.get("recording_directory"))
        reason = request.get("reason")
        if not isinstance(reason, str) or not reason:
            raise processing.ProcessingError("quarantine-record requires a reason string")
        store_root = recording_directory.parent.parent.parent
        target = store_root / ".quarantine" / f"{recording_directory.name}-{uuid.uuid4()}"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(recording_directory), str(target))
        atomic_write_text(target / "reason.txt", reason)
        return {"ok": True, "operation": operation}

    if operation == "invalidate-phase-one-dependents":
        recording_directory = existing_recording_directory(request.get("recording_directory"))
        remove_artifacts(recording_directory, PHASE_ONE_DEPENDENT_ARTIFACTS)
        return {"ok": True, "operation": operation, "recording_stem": recording_directory.name}

    if operation == "invalidate-cleanup-overlay":
        recording_directory = existing_recording_directory(request.get("recording_directory"))
        remove_artifacts(recording_directory, CLEANUP_OVERLAY_ARTIFACTS)
        return {"ok": True, "operation": operation, "recording_stem": recording_directory.name}

    if operation == "commit-record":
        return execute_commit_record(request)

    raise processing.ProcessingError("unsupported record operation")


def existing_recording_directory(raw_value: Any) -> Path:
    if not isinstance(raw_value, str) or not raw_value:
        raise processing.ProcessingError("recording_directory is required")
    directory = Path(raw_value).expanduser().resolve(strict=True)
    if not directory.is_dir() or directory.parent.name != "recordings" or directory.parent.parent.name != "Plaud":
        raise processing.ProcessingError("recording_directory must be a canonical Plaud/recordings record")
    try:
        ensure_safe_stem(directory.name)
    except ContractError as error:
        raise processing.ProcessingError(str(error)) from error
    return directory


def deletable_recording_directory(raw_value: Any) -> Path:
    """`existing_recording_directory` minus the existence requirement, for
    the one operation whose goal is the path's absence. Shape validation is
    identical (canonical Plaud/recordings parent, safe stem); resolution
    falls back to the syntactic path when the directory is already gone."""
    if not isinstance(raw_value, str) or not raw_value:
        raise processing.ProcessingError("recording_directory is required")
    candidate = Path(raw_value).expanduser()
    try:
        directory = candidate.resolve(strict=True)
    except OSError:
        directory = candidate
    if directory.exists() and not directory.is_dir():
        raise processing.ProcessingError("recording_directory must be a canonical Plaud/recordings record")
    if directory.parent.name != "recordings" or directory.parent.parent.name != "Plaud":
        raise processing.ProcessingError("recording_directory must be a canonical Plaud/recordings record")
    try:
        ensure_safe_stem(directory.name)
    except ContractError as error:
        raise processing.ProcessingError(str(error)) from error
    return directory


def validate_record_body(record: Any, *, expected_stem: str) -> None:
    if not isinstance(record, Mapping):
        raise processing.ProcessingError("record must be an object")
    if record.get("schemaVersion") != RECORD_SCHEMA_VERSION:
        raise processing.ProcessingError("record schemaVersion is not supported")
    if record.get("stem") != expected_stem:
        raise processing.ProcessingError("record stem does not match recording_directory")


def remove_artifacts(recording_directory: Path, names: tuple[str, ...]) -> None:
    for name in names:
        artifact = recording_directory / name
        if artifact.is_dir():
            raise processing.ProcessingError(f"{name} is unexpectedly a directory")
        if artifact.exists() or artifact.is_symlink():
            artifact.unlink()


def execute_commit_record(request: Mapping[str, Any]) -> dict[str, Any]:
    """Promotes an already-transferred staging directory to its canonical
    location. The staging directory arrives fully populated (meeting.json,
    audio, hints) via rsync from the client's outbox before this call, the
    same two-step shape `MeetingStore.commit()`/`commitImported()` already
    use internally (stage, validate, atomic move) - only the staging step now
    crosses machines instead of a single volume.
    """
    staging_value = request.get("staging_directory")
    if not isinstance(staging_value, str) or not staging_value:
        raise processing.ProcessingError("staging_directory is required")
    staging_directory = Path(staging_value).expanduser().resolve(strict=True)
    if not staging_directory.is_dir():
        raise processing.ProcessingError("staging_directory must be an existing directory")

    recording_value = request.get("recording_directory")
    if not isinstance(recording_value, str) or not recording_value:
        raise processing.ProcessingError("recording_directory is required")
    recording_directory = Path(recording_value).expanduser()
    if not recording_directory.parent.name == "recordings" or recording_directory.parent.parent.name != "Plaud":
        raise processing.ProcessingError("recording_directory must be a canonical Plaud/recordings record")
    try:
        ensure_safe_stem(recording_directory.name)
    except ContractError as error:
        raise processing.ProcessingError(str(error)) from error
    if recording_directory.exists():
        raise processing.ProcessingError("recording_directory already exists")

    record_path = staging_directory / "meeting.json"
    if not record_path.is_file():
        raise processing.ProcessingError("staging_directory has no meeting.json")
    try:
        record = json.loads(record_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise processing.ProcessingError("staged meeting.json is unreadable") from error
    validate_record_body(record, expected_stem=recording_directory.name)

    recording_directory.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(staging_directory), str(recording_directory))
    return {"ok": True, "operation": "commit-record", "recording_stem": recording_directory.name}


def execute_people_operation(operation: str, request: Mapping[str, Any]) -> dict[str, Any]:
    peoples_directory = processing.standalone_peoples_directory(request.get("peoples_directory"))

    if operation == "delete-person":
        return execute_delete_person(peoples_directory, request)
    if operation == "unmark-person-deleted":
        return execute_unmark_person_deleted(peoples_directory, request)
    if operation == "merge-profiles":
        return execute_merge_profiles(peoples_directory, request)
    raise processing.ProcessingError("unsupported people operation")


def _folding_key(name: str) -> str:
    """Case- and diacritic-insensitive identity key for the deleted-people
    denylist, mirroring LocalPersonProfile.foldingKey() closely enough for
    write-time dedup; the Swift client re-folds the stored raw names itself
    when reading, so the two need not be byte-identical (D-C1 follow-up)."""
    normalized = unicodedata.normalize("NFKD", name.strip())
    without_marks = "".join(character for character in normalized if not unicodedata.combining(character))
    return without_marks.casefold()


def _archive_destination(archive_root: Path, name: str) -> Path:
    destination = archive_root / name
    if destination.exists():
        stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H-%M-%SZ")
        destination = archive_root / f"{name}-{stamp}"
    return destination


def _deleted_people_path(peoples_directory: Path) -> Path:
    return peoples_directory / ".deleted-people.json"


def _read_deleted_people(peoples_directory: Path) -> list[str]:
    path = _deleted_people_path(peoples_directory)
    if not path.is_file():
        return []
    try:
        stored = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    return [item for item in stored if isinstance(item, str)] if isinstance(stored, list) else []


def _mark_people_deleted(peoples_directory: Path, names: list[str]) -> None:
    stored = _read_deleted_people(peoples_directory)
    keys = {_folding_key(item) for item in stored}
    for name in names:
        cleaned = name.strip()
        if not cleaned:
            continue
        key = _folding_key(cleaned)
        if key in keys:
            continue
        keys.add(key)
        stored.append(cleaned)
    atomic_write_json(_deleted_people_path(peoples_directory), stored)


def execute_delete_person(peoples_directory: Path, request: Mapping[str, Any]) -> dict[str, Any]:
    """Mirrors MeetingStore.deletePerson(): archive the profile folder (when
    one exists), then denylist the name and its aliases so the People list
    stops synthesizing this person from past meeting resolutions. Meetings
    keep showing the name inline; confirming it again lifts the denylist
    entry (unmark-person-deleted)."""
    name = request.get("name")
    if not isinstance(name, str) or not name.strip():
        raise processing.ProcessingError("delete-person requires a name")
    aliases = request.get("aliases", [])
    if not isinstance(aliases, list) or not all(isinstance(alias, str) for alias in aliases):
        raise processing.ProcessingError("aliases must be a list of strings")
    cleaned = name.strip()

    directory = peoples_directory / slugify(cleaned)
    archive_directory: str | None = None
    if directory.is_dir():
        archive_root = peoples_directory / "archive"
        destination = _archive_destination(archive_root, directory.name)
        archive_root.mkdir(parents=True, exist_ok=True)
        shutil.move(str(directory), str(destination))
        archive_directory = str(destination)

    _mark_people_deleted(peoples_directory, [cleaned] + aliases)
    return {"ok": True, "operation": "delete-person", "archive_directory": archive_directory}


def execute_unmark_person_deleted(peoples_directory: Path, request: Mapping[str, Any]) -> dict[str, Any]:
    name = request.get("name")
    if not isinstance(name, str) or not name.strip():
        raise processing.ProcessingError("unmark-person-deleted requires a name")
    stored = _read_deleted_people(peoples_directory)
    key = _folding_key(name)
    remaining = [item for item in stored if _folding_key(item) != key]
    if len(remaining) != len(stored):
        atomic_write_json(_deleted_people_path(peoples_directory), remaining)
    return {"ok": True, "operation": "unmark-person-deleted"}


def _notes_section(body: str) -> list[str]:
    marker = "## Notes"
    index = body.find(marker)
    if index == -1:
        return []
    notes = body[index + len(marker):]
    next_index = notes.find("\n## ")
    if next_index != -1:
        notes = notes[:next_index]
    return [line for line in notes.split("\n") if line.strip()]


def _append_notes(body: str, lines: list[str]) -> str:
    block = "\n".join(lines)
    marker = "## Notes"
    index = body.find(marker)
    if index == -1:
        stripped = body.strip("\n")
        return f"{stripped}\n\n## Notes\n{block}\n" if stripped else f"## Notes\n{block}\n"
    head = body[:index]
    tail = body[index + len(marker):]
    next_index = tail.find("\n## ")
    if next_index != -1:
        notes = tail[:next_index].strip("\n")
        rest = tail[next_index:]
        combined = f"{notes}\n{block}" if notes else block
        return f"{head}## Notes\n{combined}{rest}"
    tail_stripped = tail.strip("\n")
    combined = f"{tail_stripped}\n{block}" if tail_stripped else block
    return f"{head}## Notes\n{combined}\n"


def execute_merge_profiles(peoples_directory: Path, request: Mapping[str, Any]) -> dict[str, Any]:
    """Mirrors MeetingStore.mergeProfiles(): archive the absorbed profile
    folder verbatim first (restore is "move it back + rebuild the index"),
    then transfer meeting history, voice embedding, notes, and aliases into
    the primary profile, then remove the absorbed folder. The archive copy
    exists before anything is modified, so a failure mid-transfer never
    loses data."""
    primary_name = request.get("primary_name")
    absorbed_name = request.get("absorbed_name")
    if not isinstance(primary_name, str) or not isinstance(absorbed_name, str):
        raise processing.ProcessingError("merge-profiles requires primary_name and absorbed_name")
    primary = primary_name.strip()
    absorbed = absorbed_name.strip()
    if not primary or not absorbed or _folding_key(primary) == _folding_key(absorbed):
        raise processing.ProcessingError("merge-profiles requires two distinct people")

    absorbed_directory = peoples_directory / slugify(absorbed)
    primary_directory = peoples_directory / slugify(primary)
    absorbed_profile_path = absorbed_directory / "profile.md"
    if not absorbed_profile_path.is_file():
        raise processing.ProcessingError("absorbed profile does not exist")

    archive_root = peoples_directory / "archive"
    archive_destination = _archive_destination(archive_root, absorbed_directory.name)
    archive_root.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copytree(absorbed_directory, archive_destination)
    except OSError as error:
        raise processing.ProcessingError("could not archive the absorbed profile") from error

    today = dt.date.today().isoformat()
    absorbed_fields, absorbed_body = read_profile(absorbed_profile_path, absorbed, today)
    primary_fields, primary_body = read_profile(primary_directory / "profile.md", primary, today)
    primary_fields.setdefault("name", primary)

    aliases = primary_fields.get("aliases")
    aliases = list(aliases) if isinstance(aliases, list) else []
    absorbed_aliases = absorbed_fields.get("aliases")
    absorbed_aliases = absorbed_aliases if isinstance(absorbed_aliases, list) else []
    for alias in [absorbed] + absorbed_aliases:
        if isinstance(alias, str) and alias != primary and alias not in aliases:
            aliases.append(alias)
    primary_fields["aliases"] = aliases

    primary_stems = primary_fields.get("meeting_stems")
    primary_stems = list(primary_stems) if isinstance(primary_stems, list) else []
    absorbed_stems = absorbed_fields.get("meeting_stems")
    absorbed_stems = absorbed_stems if isinstance(absorbed_stems, list) else []
    for stem in absorbed_stems:
        if stem not in primary_stems:
            primary_stems.append(stem)
    if primary_stems:
        primary_fields["meeting_stems"] = sorted(primary_stems)
        primary_fields["meeting_count"] = max(len(primary_stems), int(primary_fields.get("meeting_count") or 0))
    else:
        combined = int(primary_fields.get("meeting_count") or 0) + int(absorbed_fields.get("meeting_count") or 0)
        if combined > 0:
            primary_fields["meeting_count"] = combined

    primary_first, absorbed_first = primary_fields.get("first_seen"), absorbed_fields.get("first_seen")
    if primary_first and absorbed_first:
        primary_fields["first_seen"] = min(primary_first, absorbed_first)
    elif absorbed_first:
        primary_fields["first_seen"] = absorbed_first

    primary_last, absorbed_last = primary_fields.get("last_seen"), absorbed_fields.get("last_seen")
    if primary_last and absorbed_last:
        primary_fields["last_seen"] = max(primary_last, absorbed_last)
    elif absorbed_last:
        primary_fields["last_seen"] = absorbed_last

    if not primary_fields.get("email") and absorbed_fields.get("email"):
        primary_fields["email"] = absorbed_fields["email"]

    # Voice embedding: transferred only when the primary has none; when both
    # carry one, the primary stays authoritative and the absorbed embedding
    # remains available in the archive.
    primary_voice = primary_directory / "voice.npy"
    absorbed_voice = absorbed_directory / "voice.npy"
    if not primary_voice.is_file() and absorbed_voice.is_file():
        primary_directory.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(absorbed_voice, primary_voice)
        if absorbed_fields.get("voice_model"):
            primary_fields["voice_model"] = absorbed_fields["voice_model"]
        if absorbed_fields.get("voice_samples"):
            primary_fields["voice_samples"] = absorbed_fields["voice_samples"]

    absorbed_notes = _notes_section(absorbed_body)
    if absorbed_notes:
        primary_body = _append_notes(primary_body, [f"{line} [{absorbed}]" for line in absorbed_notes])

    write_profile(primary_directory / "profile.md", primary_fields, primary_body)
    # Remove the absorbed folder only after the transfer landed; the archive
    # copy and (on any earlier failure) the untouched original both survive.
    shutil.rmtree(absorbed_directory)

    return {
        "ok": True,
        "operation": "merge-profiles",
        "primary_name": primary,
        "absorbed_name": absorbed,
        "archive_directory": str(archive_destination),
    }


def rpc_error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def rpc_parse_error() -> dict[str, Any]:
    return rpc_error(None, -32700, "parse error")


def handle_line(store: Store, line: str) -> dict[str, Any] | None:
    """Parse and dispatch one request line; None means the line was blank and produces no response."""
    stripped = line.strip()
    if not stripped:
        return None
    try:
        request = json.loads(stripped)
    except json.JSONDecodeError:
        return rpc_parse_error()
    if not isinstance(request, Mapping):
        return rpc_parse_error()
    return dispatch(store, request)


def main() -> int:
    parser = argparse.ArgumentParser(description="Damso canonical store write boundary (stdio line JSON)")
    parser.add_argument("--store", required=True, type=Path)
    arguments = parser.parse_args()
    store = Store.at(arguments.store)
    for line in sys.stdin:
        try:
            response = handle_line(store, line)
        except processing.ProcessingTerminated:
            return 143
        if response is None:
            continue
        print(json.dumps(response, ensure_ascii=False), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
