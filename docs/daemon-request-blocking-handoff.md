# Daemon request blocking incident and resolution

Status: resolved on 2026-08-12 by commit `c246ccc` (`Keep the daemon responsive during synchronous RPC work`).

Read this before touching `backend/damso/server/routes_v1.py`, `backend/damso/server/queue.py`, `backend/damso/speaker_hints.py`, or `backend/damso/transcript_cleanup.py`.

## Failure mode

`POST /v1/rpc` used to call synchronous Python operations directly inside an asynchronous request handler.

Some of those operations perform long-running CPU work or wait on an agent subprocess.
While that work ran on uvicorn's event-loop thread, the daemon could not accept or answer unrelated requests, including `/v1/health`.

This was observed twice on the Mac mini.
The server process stayed alive but health requests timed out until the service was restarted.
One incident showed high CPU usage, consistent with reclustering, and the other showed low CPU usage, consistent with waiting on subprocess I/O.

## Operations that required isolation

- `recluster` can rerun diarization over a full recording and hold the GIL for minutes.
- `speaker-hints` can wait up to 120 seconds for an agent subprocess.
- `transcript-cleanup` has the same subprocess-backed shape.
- `rebuild-index` scales with library size and must not block the request loop.

## Implemented resolution

The RPC contract remains synchronous from the client's perspective, but blocking work no longer runs on the server's event-loop thread.

- `speaker-hints` and `transcript-cleanup` run through `asyncio.to_thread`.
- `rebuild-index` runs in a worker thread and is protected by a process-level lock.
- `recluster` runs in a subprocess so CPU-bound inference cannot starve the event loop.
- Per-recording recluster locks prevent overlapping requests for the same meeting.
- Client-side timeouts now cover the expected duration of speaker-hint, transcript-cleanup, and recluster operations.

Phase-one and summary processing remain on their existing queue-backed subprocess path in `backend/damso/server/queue.py`.

## Regression coverage

`backend/tests/test_server_http.py` verifies that health requests remain responsive while slow RPC work is in progress.
It also covers recluster subprocess execution and same-recording concurrency protection.

`Tests/DamsoTests/LocalProcessingCommandTests.swift` verifies the expanded client timeout contracts.

Any future synchronous operation added to `/v1/rpc` must prove that it does not block the event loop under realistic load.
