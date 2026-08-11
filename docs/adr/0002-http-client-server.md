# ADR 0002: Replace the SSH transport with an HTTP client/server architecture

## Status

Accepted (2026-08). Supersedes [ADR 0001](0001-mac-mini-server-split.md) in full: the SSH stdio transport it adopted is removed, not kept alongside this one.

Partially superseded (2026-08) by [ADR 0003](0003-token-only-transport-security.md), which removes the self-signed certificate, the pinned fingerprint, and the Keychain-stored token described below in favor of a bearer token on a trusted private network. The HTTP daemon, the `/v1` and `/mcp` surface, and the processing queue this ADR established are unchanged.

## Context

ADR 0001 split detection/recording (the MacBook) from storage/processing (the Mac mini) over SSH stdio, and explicitly rejected an HTTP/gRPC transport - a new network port was judged a larger attack surface than SSH, which already provided authentication, encryption, and connection reuse for free. That decision held for a single always-on server reached by one trusted client.

Two things changed the calculus:

- **Local and remote were still two different architectures.** A single-machine ("combined") install ran everything as local subprocess calls; a two-machine install ran the identical operations over `ssh`-wrapped argv. The two paths shared logic but not a transport, so every remote-specific bug (argument-escaping, PATH resolution, connection timeouts) was a class of bug the local path never hit and never tested against.
- **The owner wants a real API boundary, not just a second machine.** Beyond storage/processing offload, the goal became a stable HTTP surface (`/v1`, OpenAPI, MCP Streamable HTTP) that any future client - not only this Mac app - could reach, which SSH's argv-and-stdio shape does not offer.

## Decision

The canonical store's owner is now a standalone Python HTTP daemon (`backend/damso/server/`), reachable at `/v1` and `/mcp`, run by `damso-server`. It is the only thing that ever touches the canonical store; the Swift app is a pure client in both modes:

- **Local mode (default).** The app spawns its own daemon bound to `127.0.0.1` on launch, manages its lifecycle (health-check, port auto-reselect on conflict, crash respawn, graceful shutdown), and talks to it exactly like a remote client would - just over loopback, with no token and no TLS (the process boundary is the trust boundary already).
- **Remote mode.** The operator runs `make install-server` on a second Apple Silicon Mac they own; it installs the daemon, generates a bearer token and a self-signed TLS certificate, and (optionally) registers a `launchd` job. The Swift app pairs by address, port, and token, pinning the certificate's fingerprint at pairing time - the same trust-on-first-use model an SSH host key uses, not a CA chain, since there is no CA. A fingerprint mismatch always means "reinstalled or something worse" and always requires a full re-pair; there is deliberately no one-click "trust this new certificate" affordance, to avoid training the owner to click through a MITM warning.

Mechanically:

- **API surface.** `/v1/rpc` reuses the existing `serve.py` dispatch verbatim for the record/people/processing operations it already covered, plus three operations (`speaker-hints`, `transcript-cleanup`, `rebuild-index`) that the SSH-era client used to reach by invoking their Python modules directly. `/v1/changes` (an incremental changelist) and per-file GET replace the `rsync` metadata mirror; `POST /v1/recordings` (a tar.gz archive upload, atomic server-side staging then commit) replaces the `rsync` outbox push. An interrupted upload is discarded whole and retried whole - no chunked/byte-range resume in this release.
- **Processing ownership.** Phase-one and summary are no longer request/response calls the client waits on. A committed upload auto-enqueues phase-one in a server-owned SQLite queue; the client uploads, then polls `/v1/recordings/{stem}/status` until it settles. Every other processing/people operation (recluster, apply-resolutions, person notes, speaker hints, transcript cleanup, index rebuild) stays a synchronous `/v1/rpc` call - only the two genuinely long-running steps moved to the queue. The client never orchestrates retries itself; `/v1/recordings/{stem}/requeue` is the one retry path, mirroring the pre-existing explicit-retry contract instead of adding silent background retries.
- **MCP.** The daemon serves MCP Streamable HTTP directly at `/mcp` under the same auth as `/v1`. `scripts/mcp-remote.sh` (an SSH-tunneling wrapper) is deleted; any MCP client that speaks Streamable HTTP points at one URL, local or remote.
- **Platform scope.** The server remains Apple Silicon-only this release - mlx-whisper has no other backend - but the transcription engine now sits behind one selection point (`processing.make_transcriber`, gated by `DAMSO_TRANSCRIBER_BACKEND`) so a non-Apple backend is a new branch there, not a rewrite. Nothing else in the server assumes macOS at the API layer.
- **Migration.** This is a clean cut, not a compatibility shim: the SSH transport, `InstanceRole.server`, and every ssh/rsync code path are removed outright, not kept behind a flag. An upgraded client that finds a leftover SSH-era preference shows an explicit "re-pair the server" notice rather than silently falling back to local mode against an empty store. The canonical store's file format is unchanged, so a re-pair moves no data.

## Consequences

- **Local and remote are now one architecture.** The bug classes ADR 0001 could only catch by testing on a real second machine (argument escaping, PATH resolution) no longer exist as a separate code path; local mode exercises the same HTTP client, auth middleware, and processing queue remote mode does, just against loopback.
- **A new security surface was introduced deliberately.** Token generation, storage (Keychain client-side, a 0600 file server-side), and revocation (`make regenerate-server-credentials`, which invalidates the old token against an already-running process on its very next request) are now Damso's own responsibility instead of SSH's. This is the dominant risk this change accepts, and it is why this PRD's implementation review profile is `high-risk` rather than `standard`.
- **Credentials are long-lived and unrotated this release.** Recovery from a leaked or lost token is regenerate-and-re-pair, not automatic rotation - acceptable at today's single-user scale, revisited if the server is ever exposed beyond a trusted LAN or shared across users.
- **Rate limiting is deferred.** The server trusts its network boundary (loopback, or a token-gated LAN) rather than defending against abusive request volume; revisit if the daemon is ever reachable from an untrusted network.
- **The external API surface is not yet a stability promise.** `/v1` is versioned (a protocol-version handshake rejects a mismatched client/server pair) and self-documented via OpenAPI, but nothing outside this Mac app depends on it yet, so no backward-compatibility guarantee has been made. That guarantee is a decision for whenever a second, independent client actually appears.
- **The processing throughput and reliability characteristics ADR 0001 measured (mlx-whisper/sherpa-onnx timing, the 25-30% slower-mini estimate) are unchanged** - this ADR only replaces how a request reaches the machine that runs them, not what runs.

## Alternatives considered

- **Keep SSH for the RPC/processing-trigger paths and move only the file-transfer paths (rsync) to HTTP.** Rejected: a hybrid transport means two connection-health models, two auth stories, and two failure modes to reason about, which directly worked against both motivating goals (one architecture, a coherent API surface).
- **Chunked/resumable upload for the outbox handoff.** Rejected for this release: outbox records are single meetings, not the multi-gigabyte transfers resumable upload exists for, and discard-and-retry-whole is simpler to reason about and test. Revisit if real usage shows large files timing out mid-upload often enough to matter.
- **Automatic credential rotation.** Rejected for the same single-user-scale reason ADR 0001 rejected automatic write retries: it would be new failure-recovery policy invented ahead of any evidence it is needed, when explicit regenerate-and-re-pair already covers the one real scenario (a leaked or lost token).
- **A CA-backed certificate instead of pinning a self-signed one.** Rejected: running a private CA for a single owner's two-machine setup is meaningfully more operational surface (issuance, revocation, trust distribution) for no benefit over pinning the exact certificate bytes at pairing time, which is already how SSH host-key trust works for the same threat model.
