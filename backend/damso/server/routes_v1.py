"""The /v1 REST surface: RPC passthrough to `damso.serve`, incremental
change listing, file access, and archive-based recording upload.

R2's "existing write operations" requirement is satisfied by reusing
`serve.dispatch` verbatim (POST /v1/rpc) rather than re-encoding each of its
thirteen operations as its own REST route - the operation contracts already
exist and are already tested; this module only adds the transport and the
genuinely new capabilities SSH used to cover with `rsync` (D-06): changes,
files, upload.
"""

from __future__ import annotations

import asyncio
import io
import json
import sys
import tarfile
import tempfile
import threading
import uuid
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse

from .. import index as index_module
from .. import serve
from .. import speaker_hints
from .. import summary as summary_module
from .. import transcript_cleanup
from ..contracts import ContractError, ensure_safe_stem
from .queue import ProcessingQueue

router = APIRouter(prefix="/v1")

# Operations `damso.serve`'s dispatch never knew about, because the SSH-era
# client invoked their modules (`damso.summary`, `damso.speaker_hints`,
# `damso.transcript_cleanup`, `damso.index`) directly instead of routing
# through `serve.py` (R2: the full local-processing surface, not only what
# serve.py already covered). Handled here, ahead of `serve.dispatch`, in the
# same request/response envelope shape so the client's existing decode logic
# needs only a transport swap, not a reshaping.
EXTRA_OPERATIONS = frozenset({"speaker-hints", "transcript-cleanup", "rebuild-index"})

# D-23: interrupted uploads are discarded and retried whole, not resumed by
# byte range, so an unbounded body would let one connection hold staging disk
# open indefinitely. 2 GiB comfortably covers a multi-hour meeting recording.
MAX_UPLOAD_BYTES = 2 * 1024 * 1024 * 1024

# The metadata filenames `damso.serve`'s record operations already know how
# to produce; used only to decide what counts as "changed" for the client's
# read cache (D-15), not to restrict which files GET /files/{name} can serve.
CHANGE_SIGNAL_FILES = ("meeting.json",)

# `rebuild-index` always writes through the same fixed `index.sqlite3.rebuild`
# staging path. Once requests can run outside the event-loop thread, two
# simultaneous rebuilds must not race each other over that one file.
_index_rebuild_lock = threading.Lock()

# Reclustering rewrites the transcript generation while transcript cleanup
# writes an index-addressed overlay for that generation. Keep those two
# mutations serialized per recording even though both now run outside the
# event loop. Access to this mapping itself stays on the event-loop thread.
_recording_mutation_locks: dict[str, asyncio.Lock] = {}


def get_store(request: Request) -> serve.Store:
    return request.app.state.store


def get_queue(request: Request) -> ProcessingQueue:
    return request.app.state.queue


@router.post("/rpc")
async def rpc(request: Request) -> dict[str, Any]:
    store = get_store(request)
    body = await request.json()
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="request body must be a JSON object")
    operation = body.get("operation")
    if operation in EXTRA_OPERATIONS:
        return await _dispatch_extra_operation(operation, body)
    # D-16: over HTTP the protocol version is negotiated by the
    # X-Damso-Protocol-Version header (the middleware in app.py 409s a
    # mismatch before this handler runs), and the client deliberately does
    # not duplicate it into the JSON body. `serve.dispatch` predates that
    # move and still enforces the SSH-era in-body field, so without this
    # injection every dispatch-routed operation (record, people, and
    # processing ops - though not EXTRA_OPERATIONS above, which skip
    # dispatch) failed with "unsupported protocol_version None" inside an
    # HTTP 200, while access logs looked healthy (found via a real
    # two-machine test: delete and summary-retry failed in the app against
    # a server whose log showed only 200s).
    body["protocol_version"] = serve.PROTOCOL_VERSION
    if operation == "recluster":
        return await _dispatch_recluster(store, body)
    response = serve.dispatch(store, body)
    if operation == "commit-record" and response.get("ok"):
        get_queue(request).enqueue_phase_one(response["recording_stem"])
    # Summary is deliberately NOT auto-enqueued after apply-resolutions:
    # existing product behavior keeps it a manual "Generate summary" action
    # (it can run on raw SPEAKER labels before confirmation, and confirming
    # speakers later does not force a re-summary) - see
    # POST /v1/recordings/{stem}/summary for the one trigger path.
    return response


async def _dispatch_extra_operation(operation: str, body: dict[str, Any]) -> dict[str, Any]:
    try:
        if operation == "speaker-hints":
            return await asyncio.to_thread(speaker_hints.execute_request, body)
        if operation == "transcript-cleanup":
            async with _recording_mutation_lock(body):
                return await asyncio.to_thread(transcript_cleanup.execute_request, body)
        if operation == "rebuild-index":
            store_root = body.get("store_root")
            if not isinstance(store_root, str) or not store_root:
                raise HTTPException(status_code=400, detail="store_root is required")
            return await asyncio.to_thread(_rebuild_index_serially, Path(store_root))
        raise HTTPException(status_code=400, detail=f"unhandled extra operation: {operation!r}")
    except HTTPException:
        raise
    except Exception as error:  # noqa: BLE001 - mirrors serve.dispatch's own boundary
        return {"ok": False, "error": {"code": "extra_operation_failed", "message": str(error)}}


async def _dispatch_recluster(store: serve.Store, body: dict[str, Any]) -> dict[str, Any]:
    """Run native diarization in a separate process while preserving RPC shape.

    A worker thread is insufficient here: sherpa-onnx performs CPU-heavy
    native inference and the server has already observed that inference
    starving the parent interpreter. `damso.processing` is the existing
    one-request JSON subprocess boundary used by the processing queue, so the
    synchronous POST/wait/response client contract does not need to change.
    """
    try:
        serve.require_request_paths_inside_store(store, body)
        async with _recording_mutation_lock(body):
            process = await asyncio.create_subprocess_exec(
                sys.executable,
                "-m",
                "damso.processing",
                "--request",
                "-",
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
            try:
                stdout, stderr = await process.communicate(json.dumps(body).encode("utf-8"))
            except BaseException:
                if process.returncode is None:
                    process.terminate()
                    await process.wait()
                raise
        try:
            response = json.loads(stdout)
        except (json.JSONDecodeError, UnicodeDecodeError) as error:
            tail = stderr.decode("utf-8", "replace")[-2_000:]
            raise RuntimeError(
                f"damso.processing exited {process.returncode} without a JSON response: {tail or '(no stderr)'}"
            ) from error
        if not isinstance(response, dict):
            raise RuntimeError("damso.processing returned a non-object JSON response")
        return response
    except Exception as error:  # noqa: BLE001 - mirrors serve.dispatch's boundary
        return {"ok": False, "error": serve.processing.public_error(error)}


def _recording_mutation_lock(body: dict[str, Any]) -> asyncio.Lock:
    key = str(body.get("recording_directory") or "")
    return _recording_mutation_locks.setdefault(key, asyncio.Lock())


def _rebuild_index_serially(store_root: Path) -> dict[str, Any]:
    with _index_rebuild_lock:
        return index_module.build_index(store_root)


@router.post("/recordings/{stem}/summary")
def request_summary(request: Request, stem: str, body: dict[str, Any] | None = None) -> dict[str, Any]:
    """The manual "generate/regenerate summary" trigger (D-13): distinct from
    the automatic enqueue after `apply-resolutions` because a user can ask for
    a fresh summary at any later point (memory: summary regeneration no
    longer requires re-confirming speakers). Goes through the same queue and
    the same status polling contract as every other trigger."""
    store = get_store(request)
    _existing_recording_directory(store, stem)
    payload = body or {}
    get_queue(request).enqueue_summary(
        stem,
        agent=payload.get("agent", "claude"),
        language=payload.get("language", "ko"),
        meeting_date=payload.get("meeting_date"),
    )
    return {"ok": True, "stem": stem, "state": "queued"}


@router.get("/changes")
def changes(request: Request, since: str | None = None) -> dict[str, Any]:
    """D-15: an incremental changelist, replacing the SSH-era `rsync -a
    --delete` cache mirror. `since` is an opaque cursor this endpoint itself
    issued (an ISO-8601 timestamp); omit it for a full listing.

    `storeRootPath` doubles as the pairing flow's one authenticated call
    (D-08: /v1/health and /v1/version stay unauthenticated, so this is the
    first request that can safely reveal a real filesystem path) - the
    client captures it once at pairing time and persists it, since every
    record-mutation RPC (`delete-record`, `update-record`, ...) needs it to
    build a `recording_directory` the server recognizes."""
    store = get_store(request)
    recordings_root = store.root / "Plaud" / "recordings"
    peoples_root = store.root / "Plaud" / "peoples"
    threshold = _parse_cursor(since)
    server_now = _now_iso()

    recordings: list[dict[str, Any]] = []
    if recordings_root.is_dir():
        for entry in sorted(recordings_root.iterdir()):
            metadata_path = entry / "meeting.json"
            if not entry.is_dir() or not metadata_path.is_file():
                continue
            mtime = metadata_path.stat().st_mtime
            if threshold is not None and mtime <= threshold:
                continue
            recordings.append({"stem": entry.name, "updatedAt": mtime})

    people: list[dict[str, Any]] = []
    if peoples_root.is_dir():
        for entry in sorted(peoples_root.iterdir()):
            profile_path = entry / "profile.md"
            if not entry.is_dir() or not profile_path.is_file():
                continue
            mtime = profile_path.stat().st_mtime
            if threshold is not None and mtime <= threshold:
                continue
            people.append({"slug": entry.name, "updatedAt": mtime})

    return {"cursor": server_now, "recordings": recordings, "people": people, "storeRootPath": str(store.root)}


@router.get("/recordings/{stem}/files/{filename}")
def get_recording_file(request: Request, stem: str, filename: str) -> FileResponse:
    """Serves any regular file directly inside one recording directory -
    metadata (transcript.json, summary.json, ...) and audio alike, replacing
    both the rsync metadata mirror and the on-demand audio fetch (D-15, R5)."""
    store = get_store(request)
    recording_directory = _existing_recording_directory(store, stem)
    if "/" in filename or filename in {".", ".."} or filename.startswith("."):
        raise HTTPException(status_code=400, detail="filename must be a plain, non-hidden basename")
    target = recording_directory / filename
    if not target.is_file() or target.is_symlink():
        raise HTTPException(status_code=404, detail="file not found")
    if target.parent != recording_directory:
        raise HTTPException(status_code=400, detail="filename must stay inside the recording directory")
    return FileResponse(target)


@router.get("/recordings/{stem}/status")
def recording_status(request: Request, stem: str) -> dict[str, Any]:
    store = get_store(request)
    _existing_recording_directory(store, stem)
    status = get_queue(request).status(stem)
    if status is None:
        return {"stem": stem, "state": "idle"}
    return status


@router.post("/recordings/{stem}/requeue")
def requeue(request: Request, stem: str) -> dict[str, Any]:
    """R3's manual-retry contract: re-runs processing for an existing
    recording. A failed job is flipped back to queued; otherwise a fresh
    phase-one is enqueued - the client's "Retry processing" deliberately
    resets an already-processed record for a full re-run from the server's
    stored audio, and its most recent job is then typically a *successful*
    one (e.g. a done summary), so "no failed job" must not be an error.
    Confirmed via a real two-machine run: 404ing that case left the client
    stranded with a record it had already reset - artifacts invalidated,
    stage failed, and no way forward."""
    store = get_store(request)
    _existing_recording_directory(store, stem)
    queue = get_queue(request)
    if not queue.requeue(stem):
        queue.enqueue_phase_one(stem)
    return {"ok": True, "stem": stem, "state": "queued"}


@router.post("/recordings")
async def upload_recording(request: Request) -> JSONResponse:
    """D-23: the outbox arrives as one tar archive (meeting.json + audio +
    any hint files, whatever the client's outbox record directory holds) and
    is extracted into a fresh internal staging directory, then promoted
    atomically - mirroring `execute_commit_record`'s stage/validate/move
    shape, except the staging path is server-chosen now that the client no
    longer has filesystem access to the server (D-06). An interrupted or
    corrupt archive fails extraction/validation and nothing is committed:
    the client's local outbox copy is untouched, so retry means "upload the
    whole archive again", not "resume a partial write" (D-23 explicitly
    rejects byte-range resume for this release)."""
    store = get_store(request)
    content_length = request.headers.get("content-length")
    if content_length is not None and int(content_length) > MAX_UPLOAD_BYTES:
        raise HTTPException(status_code=413, detail="upload exceeds the maximum recording size")

    body = await _read_bounded(request, MAX_UPLOAD_BYTES)

    staging_root = store.root / ".staging"
    staging_root.mkdir(parents=True, exist_ok=True)
    staging_directory = staging_root / uuid.uuid4().hex

    try:
        _extract_archive_safely(body, staging_directory)
        record = _read_and_validate_staged_record(staging_directory)
    except (ContractError, tarfile.TarError, OSError, EOFError, json.JSONDecodeError) as error:
        # EOFError: a truncated gzip stream (interrupted upload, D-23) - the
        # archive is simply incomplete, not a different failure mode.
        _discard(staging_directory)
        raise HTTPException(status_code=422, detail=f"invalid recording archive: {error}") from error

    stem = record["stem"]
    recording_directory = store.root / "Plaud" / "recordings" / stem
    if recording_directory.exists():
        _discard(staging_directory)
        raise HTTPException(status_code=409, detail="a recording with this stem already exists")

    commit_response = serve.dispatch(
        store,
        {
            "protocol_version": serve.PROTOCOL_VERSION,
            "operation": "commit-record",
            "staging_directory": str(staging_directory),
            "recording_directory": str(recording_directory),
        },
    )
    if not commit_response.get("ok"):
        _discard(staging_directory)
        raise HTTPException(status_code=422, detail=commit_response.get("error", "commit failed"))

    get_queue(request).enqueue_phase_one(stem)
    return JSONResponse({"ok": True, "recording_stem": stem}, status_code=201)


def _existing_recording_directory(store: serve.Store, stem: str) -> Path:
    try:
        ensure_safe_stem(stem)
    except ContractError as error:
        raise HTTPException(status_code=400, detail=str(error)) from error
    directory = store.root / "Plaud" / "recordings" / stem
    if not directory.is_dir():
        raise HTTPException(status_code=404, detail="recording not found")
    return directory


async def _read_bounded(request: Request, limit: int) -> bytes:
    buffer = io.BytesIO()
    total = 0
    async for chunk in request.stream():
        total += len(chunk)
        if total > limit:
            raise HTTPException(status_code=413, detail="upload exceeds the maximum recording size")
        buffer.write(chunk)
    return buffer.getvalue()


def _extract_archive_safely(body: bytes, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    with tarfile.open(fileobj=io.BytesIO(body), mode="r:gz") as archive:
        members = []
        for member in archive.getmembers():
            if not (member.isfile() or member.isdir()):
                raise tarfile.TarError("archive must contain only plain files and directories")
            member_path = Path(member.name)
            if member_path.is_absolute() or ".." in member_path.parts:
                raise tarfile.TarError("archive entry escapes the recording directory")
            # macOS archivers smuggle resource-fork metadata in as AppleDouble
            # sidecars ("._microphone.caf", ".DS_Store"). Extracted literally
            # they masquerade as extra audio files - a real upload from the
            # Mac client failed phase-one with "more than two audio files
            # found" because "._microphone.caf" and "._system-audio.m4a"
            # counted as audio. They carry nothing the store needs, so they
            # are dropped at the door rather than special-cased downstream.
            if member_path.name.startswith("._") or member_path.name == ".DS_Store":
                continue
            members.append(member)
        archive.extractall(destination, members=members, filter="data")


def _read_and_validate_staged_record(staging_directory: Path) -> dict[str, Any]:
    record_path = staging_directory / "meeting.json"
    if not record_path.is_file():
        raise ContractError("archive has no meeting.json")
    record = json.loads(record_path.read_text(encoding="utf-8"))
    if not isinstance(record, dict):
        raise ContractError("meeting.json must be an object")
    stem = record.get("stem")
    if not isinstance(stem, str) or not stem:
        raise ContractError("meeting.json is missing a stem")
    ensure_safe_stem(stem)
    return record


def _discard(staging_directory: Path) -> None:
    if staging_directory.is_dir():
        import shutil

        shutil.rmtree(staging_directory, ignore_errors=True)


def _parse_cursor(raw: str | None) -> float | None:
    if not raw:
        return None
    import datetime as dt

    try:
        return dt.datetime.fromisoformat(raw).timestamp()
    except ValueError:
        raise HTTPException(status_code=400, detail="since must be an ISO-8601 timestamp") from None


def _now_iso() -> str:
    import datetime as dt

    return dt.datetime.now(dt.timezone.utc).isoformat()
