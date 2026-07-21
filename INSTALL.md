# Damso installation

Damso is a local macOS application with a Swift app shell and a Python helper package.
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

## Local setup

Create and activate a virtual environment if your Python installation requires one.
Install the local processing helper with `python -m pip install -e '.[local-processing]'` so the Settings action can run the fixed local setup module.
Alternatively, install the dependencies with `python -m pip install -r requirements-local.txt`.
Run `make verify-static` to compile the Swift app and Python package.
Run `make install-local-app` to build the app, install it as `~/Applications/Damso.app`, register it with Launch Services, and launch it.
The installed bundle is what makes Spotlight, Launchpad, Launch at Login, and persistent macOS permissions work; `swift run Damso` runs the same app unbundled and is only for iterating on code.
On the first recording macOS shows Microphone and Screen Recording permission dialogs; approving them must stay a manual user action.
Set `DAMSO_STORE` to the canonical store root that should contain `Plaud/recordings` and `Plaud/peoples`.
By default, models live under the app's local Application Support folder (`~/Library/Application Support/Damso`).
Set `DAMSO_MLX_WHISPER_MODEL_DIR` and `DAMSO_SHERPA_MODEL_DIR` only when you deliberately use another local model directory.
Run `make doctor` to check the storage root, commands, and model paths without uploading meeting data.

```sh
export DAMSO_STORE="$HOME/Library/Application Support/Damso"
python -m pip install -e '.[local-processing]'
make install-local-models
make doctor
make test
make install-local-app
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

The app invokes the local processing helper as one JSON request over stdin and reads the resulting artifacts from the canonical record folder.
The helper accepts only an existing Plaud/recordings/{stem} directory, audio stored inside that record, and its sibling Plaud/peoples registry.
It never accepts a shell command, network URL, or an arbitrary output path.
The process writes a small status response without transcript text or absolute paths.

    printf '%s' '{"operation":"apply-resolutions","recording_directory":"/path/to/store/Plaud/recordings/example","peoples_directory":"/path/to/store/Plaud/peoples","resolutions":{"SPEAKER_00":{"action":"new","name":"Example"}}}' | python3 -m damso.processing --request -

Use this command only with synthetic or already-approved local data.

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

`index.sqlite3` at the store root is a derived SQLite search index over meetings, people, and their relations.
The files stay canonical: the index is rebuilt deterministically from `meeting.json`, `summary.json`, transcripts, and profiles, with no LLM call and no network access.
The app refreshes it after each pipeline step; rebuild it manually with `make reindex` or the **Rebuild search index** action in Settings.

## Local MCP

The MCP server reads the canonical store and its SQLite index through stdio.
It does not bind a network listener and does not expose a write tool.
The tools are `search_meetings`, `get_meeting`, and `get_speaker`; their response fields are stable and only ever extended.

```sh
export DAMSO_STORE="$HOME/Library/Application Support/Damso"
make mcp
```

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

## Sample data and public repository hygiene

Keep recordings, transcripts, voice embeddings, speaker profiles, Plaud profile data, session values, diagnostics exports, and local virtual environments outside Git.
The test suite creates synthetic data in temporary directories, and `fixtures/private/` is ignored for any local-only fixture.
Only redacted command output and screenshots containing synthetic meeting content may be kept as verification evidence.

Before a future remote publication, review the files about to be added for user-specific paths and sensitive data, then run `git diff --check` and the documented automated checks.
Do not add raw browser profiles, environment files, session values, or a copied `config.example.json` containing machine-specific values.
This repository is published under the [MIT License](LICENSE).
