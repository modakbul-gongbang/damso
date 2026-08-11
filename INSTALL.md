# Damso installation

Damso is a Swift app (detection, recording, UI) and a Python HTTP daemon (canonical store, processing, MCP) that talks to it over `/v1`.
Installation is two units (`make install-server`, `make install-client`); a single-machine setup runs both on the same Mac.
It does not bundle Python, local models, the Plaud CLI, or an agent CLI (Claude Code / Codex).
It never installs or signs in to any runtime without an explicit user action.
Automatic summaries run through your already-signed-in agent CLI after you confirm a meeting's speakers; see the Privacy model section of [README.md](README.md) before enabling one.

This document is written as an installation contract that an AI coding agent can execute step by step.
Each section states what to run, what the expected outcome is, and which actions must stay manual.

## Prerequisites

Install the current Xcode command line tools or full Xcode so that `swift --version` works.
Install Python 3.11 or newer for the local helper package.
Install `ffmpeg` before enabling local sherpa-onnx diarization.
Install Node.js and `npm install -g @plaud-ai/cli` only if the user wants Plaud wearable synchronization (External Sync).
Install `chromux` only if the user wants live participant-name capture from browser meeting tabs.
Install and sign in to the Claude Code CLI or the Codex CLI if you want automatic summaries and titles; select the default agent in Damso Settings.
Keep the mlx-whisper large-v3-turbo and sherpa-onnx diarization models in local directories you control.

## Local setup (single Mac: server + client together)

The common case - one Mac does detection, recording, storage, and processing.
No pairing and no token: the app spawns its own HTTP daemon on `127.0.0.1` when it starts (D-05/D-08).

Create and activate a virtual environment if your Python installation requires one.
Set `DAMSO_STORE` to the canonical store root that should contain `Plaud/recordings` and `Plaud/peoples`.
Run `make install-server` to install the processing + HTTP daemon package and the local models.
Run `make install-client` to build the Swift app, install it as `~/Applications/Damso.app`, register it with Launch Services, and launch it.
The installed bundle is what makes Spotlight, Launchpad, Launch at Login, and persistent macOS permissions work; `swift run Damso` runs the same app unbundled (against a daemon it spawns the same way) and is only for iterating on code.
On the first recording macOS shows Microphone and Screen Recording permission dialogs; approving them must stay a manual user action.
By default, models live under the app's local Application Support folder (`~/Library/Application Support/Damso`).
Set `DAMSO_MLX_WHISPER_MODEL_DIR` and `DAMSO_SHERPA_MODEL_DIR` only when you deliberately use another local model directory.
Run `make doctor` to check the storage root, commands, and model paths without uploading meeting data.

```sh
export DAMSO_STORE="$HOME/Library/Application Support/Damso"
make install-server
make doctor
make test
make install-client
```

## Configuration contract

The Swift app uses a local Application Support directory until the user explicitly selects an existing local storage root.
The selected app root is stored as a user preference and is never silently moved or replaced with a fallback root.
The Python helper, MCP server, and diagnostics use `DAMSO_STORE` so terminal use targets the same canonical root deliberately.
The default local model directories are `~/Library/Application Support/Damso/Models/mlx-whisper-large-v3-turbo` and `~/Library/Application Support/Damso/Models/sherpa-diarization`.
`DAMSO_MLX_WHISPER_MODEL_DIR` and `DAMSO_SHERPA_MODEL_DIR` can override those locations with directories managed by the user.
Open Damso Settings and select **Install local models** to explicitly download the pinned Python dependencies, MLX Whisper large-v3-turbo model, and Sherpa diarization models into the local default directory.
The confirmation explains that this is the only action that accesses the fixed model providers, and it never uploads meeting audio, transcripts, Plaud sessions, or credentials.
`config.example.json` is a redacted, machine-neutral reference for the values an installation needs.
The current runtime does not read that file automatically, so do not put secrets or real meeting data in a copied configuration file.

`make doctor` creates and removes a small write probe under the chosen root.
It reports Python, `ffmpeg`, `chromux`, the agent CLIs (`claude`, `codex`), `sandbox-exec`, both local processing Python modules, the storage root, and both model directories without reading recordings or sending data over the network.
A single missing agent CLI is a warning; doctor only blocks when neither agent CLI is installed.
It returns a nonzero status when a required local dependency is unavailable so setup can be corrected before recording.

## Local model provisioning

The Settings button and `make install-local-models` invoke one constrained Python module with no shell interpolation and no configurable URL input.
They install only the pinned local-processing packages, `mlx-community/whisper-large-v3-turbo`, the Sherpa pyannote segmentation archive, and the Sherpa 3D-Speaker embedding model.
The action can be repeated safely after an interrupted download because the readiness check verifies the required local files before reporting success.
Use `make model-status` to inspect only redacted readiness state.
Upgrading an earlier install downloads the turbo model into a new `mlx-whisper-large-v3-turbo` directory of about 1.5 GB.
The previous `mlx-whisper-large-v3` directory of about 2.9 GB is no longer read and can be deleted.

## Local processing boundary

The app reaches the canonical store only through the HTTP daemon's `/v1` API (D-05/D-06) - local mode over `127.0.0.1`, remote mode over your own private network with a bearer token (ADR 0003).
Synchronous operations (apply-resolutions, recluster, person notes, speaker hints, transcript cleanup, index rebuild) are one POST to `/v1/rpc` each; phase-one and summary are queue-based, triggered by an upload/trigger call and watched with `/v1/recordings/{stem}/status` polling (D-13).
The daemon accepts only an existing Plaud/recordings/{stem} directory, audio stored inside that record, and its sibling Plaud/peoples registry - never a shell command, network URL, or an arbitrary output path.

```sh
curl -s http://127.0.0.1:8787/v1/rpc -H 'Content-Type: application/json' -d '{"protocol_version":1,"operation":"apply-resolutions","recording_directory":"/path/to/store/Plaud/recordings/example","peoples_directory":"/path/to/store/Plaud/peoples","resolutions":{"SPEAKER_00":{"action":"new","name":"Example"}}}'
```

Use this command only with synthetic or already-approved local data, against a daemon you started yourself (`python3 -m damso.server.main --store "$DAMSO_STORE"`).

## External Sync (Plaud CLI) contract

External Sync imports recordings from a Plaud account through the official `@plaud-ai/cli`, read-only.
Install the CLI with `npm install -g @plaud-ai/cli`; Damso locates it on the runtime PATH and in nvm-managed Node installations.
Sign in by pressing **Connect** in Damso Settings → External Sync, or by running `plaud login` in a terminal; the CLI opens a browser window and stores its own session under `~/.plaud`.
Damso never reads, stores, logs, or displays that token; authentication state is observed only through the CLI's exit codes (0 ok, 2 authentication expired).
While connected, Damso checks for new recordings once an hour and on manual **Sync now**, importing recordings from the last 7 days.
Each import is staged, validated as playable audio, and committed atomically; a per-provider checkpoint at `<store root>/.external-sync/plaud.json` holds the watermark and import index so a recording is never imported twice.
Imported meetings enter the normal local pipeline sequentially and are labeled with their source provider in the meeting list and detail view.
When the Plaud session expires, Damso shows a re-login badge and sends one notification; sign in again from Settings to resume.
Do not automate `plaud login` and do not copy session files between machines.

## Search index

`index.sqlite3` at the store root is a derived SQLite search index over meetings, people, and their relations, including an FTS5 (trigram tokenizer) full-text index used for keyword search.
The files stay canonical: the index is rebuilt deterministically from `meeting.json`, `summary.json`, transcripts, and profiles, with no LLM call and no network access.
The app refreshes it after each pipeline step; rebuild it manually with `make reindex` or the **Rebuild search index** action in Settings.
Opening an index built by an older version of Damso automatically triggers a synchronous rebuild on the next search, so no manual migration step is needed after an update.
If the local sqlite3 build lacks FTS5/trigram support, keyword search returns an explicit error instead of silently falling back to a lower-quality match; date/speaker-only search and `get_meeting`/`get_speaker` are unaffected either way.

## MCP

The HTTP daemon serves MCP Streamable HTTP at `/mcp` (D-07) - the same URL shape for local and remote, under the same auth as the rest of `/v1` (none on loopback, a bearer token remotely).
It exposes no write tool.
The tools are `search_meetings`, `get_meeting`, `get_speaker`, and `search_people`; their response fields are stable and only ever extended.
`search_meetings` and `search_people` keyword matches are ranked by BM25 relevance and include a `snippet` field with matching context; filtering by date or speaker alone keeps the original newest-first order.
`search_people(keyword)` searches profile names and the free-text Notes section, returning candidate people (`name`, `slug`, `meetingCount`, `snippet`) for when you don't remember an exact name.

Point an MCP client at `http://127.0.0.1:8787/mcp` for a local-mode store, or `http://<server-host>:<port>/mcp` with the paired token (`Authorization: Bearer <token>`) for a remote one. There is no certificate to trust and no host alias to add - the URL and the header are the whole configuration.

### Registering the server with a client

For Claude Code, local mode needs no token because the middleware skips authentication entirely on a loopback bind:

```sh
claude mcp add --transport http damso http://127.0.0.1:8787/mcp
```

For a remote store, pair the app first (Settings → **Server Mac**, or the two-machine section below).
Pairing writes the token to `~/Library/Application Support/Damso/.client-credentials/server-token` with mode `0600`, so the registration can read it out of the file instead of putting the secret in your shell history:

```sh
claude mcp add --transport http damso \
  "http://<server-host>:8787/mcp" \
  --header "Authorization: Bearer $(cat ~/Library/Application\ Support/Damso/.client-credentials/server-token)"
```

`claude mcp add` defaults to `--scope local`, which registers the server only for the directory it was run from; use `--scope user` to make it available everywhere.
Other MCP clients take the same two values in whatever configuration format they use - a `url` and an `Authorization: Bearer <token>` header.

### Where the token lives

The server generates the token once, during `make install-server`, and prints it exactly once.
It is stored on the server Mac at `~/Library/Application Support/Damso/.server-credentials/token` (mode `0600`), and that file is the only copy the daemon consults - it is re-read per request, so `make regenerate-server-credentials` invalidates every paired client immediately, without a restart.
The client's copy is the `.client-credentials/server-token` file above, anchored to the fixed application-support directory rather than the store root so it never travels with a store export or relocation.
Both are plain files, not Keychain items.

### When it does not connect

`/v1/version` answers `200` without a token whenever the daemon is up, which separates "the server is unreachable" from "my token is wrong":

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://<server-host>:8787/v1/version   # 200 = daemon is up
curl -s -o /dev/null -w '%{http_code}\n' http://<server-host>:8787/mcp          # 401 = expected without a token
```

A hang or a connection refusal on the first command means the daemon is down or the address is unreachable; check `launchctl print gui/$(id -u)/com.yansfil.damso.server` and `~/Library/Logs/Damso/server.log` on the server Mac.
A `401` on `/mcp` while `/v1/version` returns `200` means the token is missing, stale, or was regenerated - re-pair in Settings and re-register the MCP server with the new value.
Requests other than `/v1/health` and `/v1/version` require the token, including `/openapi.json` and `/docs`.

## Agent CLI boundary

After the speakers of a meeting are confirmed, Damso automatically sends the meeting's transcript text to the selected agent CLI (Claude Code or Codex) through stdin to produce the structured summary, the `YYYYMMDDHH-title` display title, and person-note proposals.
Every agent run uses an empty temporary cwd, disables agent tools (Claude `--tools ""`, Codex `--sandbox read-only`), requires `sandbox-exec` with an explicit deny rule on the meeting store, limits timeout and output size, and accepts only a schema-validated JSON response.
It does not accept, display, or store an API key.
If the selected CLI is missing or not signed in, the summary stage stops in a retryable dependency state with a Settings recovery action; the app never falls back to the other agent silently.
The generated summary language follows the in-app language setting (Korean by default).

## Live verification

`make verify-live-plaud`, `make verify-live-llm`, and `make verify-daily-driver` intentionally exit blocked until a user performs the required safe probe.
They never log in to Plaud, begin a recording, or invoke a paid agent CLI request automatically.
Use [verification.md](docs/verification.md) for the required human checks and redacted evidence rules.

## Legacy isolation

New recordings, Plaud sync, local processing, summaries, and MCP reads run only from this repository's Swift and Python sources.
The legacy vault is an optional source for an explicitly approved copy-only migration and is not a runtime dependency.
Do not configure a legacy vault path as a destination for new Damso records.

## Storage migration, backup, restore, and relocation

Use `damso-storage preview-copy` before any copy, backup, restore, or root-relocation action.
The preview makes no change and reports planned copies, identical records, collisions, and failures.
The mutating actions require `--confirm` and never delete or silently move the source root.
Backup, restore, and relocation require a valid canonical `store.json` schema manifest and verify record and speaker checksums before restore.
Use synthetic paths until the owner explicitly approves a real vault migration or storage move.

```sh
PYTHONPATH=backend python3 -m damso.migration preview-copy --source /path/to/source --target /path/to/target
PYTHONPATH=backend python3 -m damso.migration backup --source /path/to/canonical-store --target /path/to/backup --confirm
PYTHONPATH=backend python3 -m damso.migration restore --source /path/to/backup --target /path/to/restored-store --confirm
PYTHONPATH=backend python3 -m damso.migration relocate-copy --source /path/to/canonical-store --target /path/to/new-root --confirm
```

## Two-machine setup (server Mac)

Optional. By default Damso does everything on one Mac; this section only applies if you want a second Mac you own to hold the canonical store and run processing while your laptop stays on detection, recording, and the UI. See the ADR at `docs/adr/0002-http-client-server.md` for why this shape was chosen (it supersedes the earlier SSH-based `0001-mac-mini-server-split.md`).

The server does not have to be a Mac mini - any always-on Mac works - but it does have to be **Apple Silicon** for this release, because transcription runs on mlx-whisper and MLX is Apple Silicon only.
It needs no Xcode and no git checkout: `make install-server` is a plain Python install run directly on that machine.

### On the server Mac

1. Get this repository onto the server (a `git clone`, or copy the working tree - it does not need to be the same checkout as the client).
2. Set `DAMSO_STORE` to where the canonical store should live there, and run install with the background service enabled:
   ```sh
   export DAMSO_STORE="$HOME/Library/Application Support/Damso"
   export DAMSO_SERVER_RESIDENT=1   # registers a launchd job so the daemon survives logout/reboot
   make install-server
   ```
   This installs the pinned processing + HTTP daemon dependencies, downloads the local models if missing, generates an access token under `~/Library/Application Support/Damso/.server-credentials` (D-08/D-24), and (because `DAMSO_SERVER_RESIDENT=1`) writes and loads the `com.yansfil.damso.server` LaunchAgent bound to `0.0.0.0:8787`.
3. **Save the printed access token now** - it is not printed again. If you lose it, `make regenerate-server-credentials` issues a new one and immediately invalidates the old one (every paired client will need to re-pair).
4. If you already have a canonical store elsewhere, copy it into place with a plain recursive copy before the daemon's first request touches `$DAMSO_STORE` - `damso.migration` is for backup/restore/relocation snapshots, not a live move.

### On the client Mac

5. Run `make install-client` (or use an already-installed `~/Applications/Damso.app`).
6. Open Damso Settings → **Server Mac**, turn on **Use another Mac for storage and processing**, enter the server's address, port, and the access token from step 3, then press **Check**. The app confirms the server's protocol version and that the token is accepted before you save (D-08). If the address is not on a private network (RFC1918, a Tailscale `100.64/10`/`*.ts.net` address, or loopback), it warns you: the connection carries no encryption of its own, so it belongs on a network that already provides it.
7. Press **Save and use this Mac**, then reopen Damso.

### Afterwards

8. **Point your MCP client at the server.** Any MCP client that supports Streamable HTTP can reach `http://<server-host>:<port>/mcp` directly with the same bearer token - no wrapper script, no certificate to trust (D-07).
9. **Confirm ordinary use still works end to end**: record on the laptop, confirm speakers, and check that the summary and title appear - all reads and writes should route through the server transparently. `make verify-static` and `make test` must pass on both machines independently after any code change.

### If you are upgrading from the SSH-based two-machine setup

The old `RemoteExecutionConfiguration`/SSH transport (ADR 0001) is gone; this is a clean cut, not a compatibility shim (D-12).
The client detects a leftover SSH-era preference and shows a re-pairing notice instead of silently falling back to local mode.
A client left over from the later HTTPS pairing (ADR 0002) is detected separately and shown its own re-pairing notice; both paths end at the same place, a fresh token and a new pairing.
Your canonical store on the server is untouched and does not move - run `make install-server` there (steps 1-3 above), then re-pair the client (steps 5-7).

### Losing the server

`make uninstall-server` stops and removes the background service and deletes the access token.
It never touches the canonical store - that is a separate, deliberate action you take yourself if you actually want to delete your meeting data.

## Sample data and public repository hygiene

Keep recordings, transcripts, voice embeddings, speaker profiles, Plaud profile data, session values, diagnostics exports, and local virtual environments outside Git.
The test suite creates synthetic data in temporary directories, and `fixtures/private/` is ignored for any local-only fixture.
Only redacted command output and screenshots containing synthetic meeting content may be kept as verification evidence.

Before a future remote publication, review the files about to be added for user-specific paths and sensitive data, then run `git diff --check` and the documented automated checks.
Do not add raw browser profiles, environment files, session values, or a copied `config.example.json` containing machine-specific values.
This repository is published under the [MIT License](LICENSE).
