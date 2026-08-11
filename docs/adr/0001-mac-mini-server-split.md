# ADR 0001: Split detection/recording (MacBook) from storage/processing (Mac mini)

## Status

Superseded (2026-08) by [ADR 0002](0002-http-client-server.md), which replaces the SSH stdio transport described below with an HTTP client/server architecture. Kept for historical context; the SSH transport itself no longer exists in the codebase.

## Context

Damso originally ran entirely on one Mac: the same process detected meetings, recorded audio, ran local transcription and diarization, owned the canonical file store, and served the local MCP index. That model has two costs that only show up with sustained use:

- Local transcription and diarization for a 55-minute meeting take roughly 8 minutes of wall clock (measured: 471s), almost all of it CPU-bound diarization. Running that on a MacBook that is also being used for other work is disruptive, and running it only when the MacBook happens to be awake and plugged in means processing backlogs when it isn't.
- The canonical store (recordings, transcripts, profiles, the derived search index) lives wherever the MacBook happens to keep it, with no separation between "the machine I carry around" and "the machine that should always be on."

A user who already owns an always-on Mac mini wanted the option to move the canonical store and heavy processing there, while keeping meeting detection, recording, and the UI on the MacBook where the meetings actually happen.

## Decision

Split the single role into two, selected per-instance by `InstanceRole` (`Sources/Damso/Core/InstanceRole.swift`):

- **Server (Mac mini).** Owns the canonical store and runs all processing (transcription, diarization, summarization). Never watches the microphone or browser tabs, so it never triggers the mic/screen-recording/Apple Events permission prompts detection would cause. Selected by launching with the `--server-role` argument.
- **Client (MacBook).** Detects meetings, records, and shows the UI. Never decides when to resume stuck processing itself - that sweep is the server's job against the store it owns - but still ssh-invokes `damso.processing`/`damso.summary`/etc. for its own freshly captured recordings, and still transfers audio to the mini. Selected automatically whenever a remote store is configured; a remote configuration always wins over `--server-role`, so the two signals can never conflict.
- **Combined (default, single machine).** Everything as before. Selected when neither of the above applies.

Mechanically:

- **Transport.** SSH stdio, line-delimited JSON, mirroring the existing local MCP server's own `dispatch()`/`main()` shape (`backend/damso/serve.py`). No new port, no new dependency, no persistent daemon beyond what a LaunchAgent already provides. Every remote invocation - `damso.serve`, `damso.processing`, `damso.summary`, cache sync, outbox handoff, on-demand audio fetch - goes through one shared `CommandLauncher`/`RemoteConnectivityTracker` pair on the Swift side, so the ssh-argument-escaping and PATH pitfalls below are fixed in one place rather than at each call site.
- **Writes.** The MacBook never writes the canonical store directly. `damso.serve` gained update/delete/quarantine/commit/merge-profile/etc. operations mirroring the existing Swift `MeetingStore` write surface exactly, so no new write policy was invented - existing logic was ported, not redesigned.
- **New recordings.** A recording in progress writes to a local outbox on the MacBook, not directly to the mini and not to the read cache, because live audio capture must stream to local disk regardless of connectivity (a network path as the recording target risks losing the meeting on a dropped connection). Once capture stops, the outbox record is rsync-pushed to the mini's `.staging` and atomically promoted (`commit-record`), the same staging-then-atomic-move shape the existing local store already used for crash safety.
- **Reads.** The MacBook mirrors cheap metadata (not audio, not the derived SQLite index) into a local cache via a periodic `rsync -a --delete`, so browsing, transcripts, and summaries keep working offline; audio is fetched on demand only when actually needed for playback.
- **Connection status.** No dedicated health-check ping. A lock-guarded `RemoteConnectivityTracker` is updated as a side effect of every real remote call already happening (`damso.serve`, cache sync, outbox handoff, audio fetch), and a write action started while the last known status isn't `connected` is blocked immediately with a distinct disconnected/version-mismatch message instead of being attempted and left to time out.

## Consequences

- **Processing throughput is expected to drop 25-30%** on the mini's older hardware relative to the MacBook's current one (estimated: ~471s to ~600s for the same 55-minute meeting - not yet measured on the real mini; revisit the estimate once it has run enough real meetings) - accepted regardless, since the alternative was not processing at all while the MacBook is busy or asleep.
- **Two privacy statements in the README stopped being literally true** and were corrected: audio now leaves the MacBook (to a mini the user owns, never a third party) once a two-machine setup is configured, and the MCP server's own stdio protocol still never opens a socket, but the client that launches it over ssh does open one - to the configured mini only.
- **A non-interactive SSH shell's `PATH` is minimal** (`/usr/bin:/bin:/usr/sbin:/sbin`), so every remote interpreter path and store root must be absolute; this project encodes that as a hard `CommandLauncher` requirement rather than trusting shell config on either machine.
- **SSH joins all arguments after the host into one string** for the remote shell to re-tokenize, which would silently split any path containing a space (the real default store path contains two). Fixed once in `CommandLauncher.shellQuote`/`argv`, reused everywhere, including the standalone `scripts/mcp-remote.sh` wrapper for MCP clients (which cannot depend on the Swift app's own code).
- **A shared machine now runs another resident background process.** The mini already runs several other users' background agents; the server role is deliberately built to never touch the microphone, screen recording, or Apple Events, so it adds no new permission surface on that machine.

## Alternatives considered

- **A small HTTP/gRPC service on the mini instead of SSH stdio.** Rejected: a new network port is a larger attack surface and a new dependency, and SSH already provides authentication, encryption, and connection reuse (ControlMaster) for free. `dispatch()` is deliberately transport-agnostic, so an HTTP shell remains possible later without touching the logic.
- **`damso.migration`'s existing backup/restore/relocate tooling for the initial store move.** Rejected for this one-time transfer: that tool is schema-and-checksum-oriented for snapshot operations, not a live-store move, and a plain `rsync -a` is simpler to verify byte-for-byte for a single copy performed once before the mini's Damso instance ever starts.
- **Automatic retries for a failed remote write.** Rejected: the existing local-processing error model already requires an explicit user retry rather than silent background retries, and extending that same contract to remote writes avoids inventing a second failure-recovery policy.
- **A persistent "connected/disconnected" banner.** Rejected: most of the time the connection is fine, and a banner that is present 99% of the time trains users to ignore it. A small indicator that only appears when degraded, plus blocking the specific action at the moment it's attempted, carries the same information with far less visual noise.
