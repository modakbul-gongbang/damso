# Damso verification protocol

## Automated checks

Run `make test` for Swift and Python unit coverage.
Run `make verify-portability` from a clean clone with only documented runtime paths configured.
Run `make verify-local-resilience` to exercise storage commits, recovery queue behavior, scheduler backoff, migration copies, and the Claude boundary contract.

## Required human checks

Before declaring a daily-driver build complete, explicitly approve the design review in `docs/design/damso-hv1.md`.
Grant microphone and screen or system-audio permissions and verify that a real local meeting contains both sources.
Run a two-hour recording and inject an input-device disconnect without claiming completion for a partial record.
Force quit during transcription, speaker review, and summary states and confirm that the durable queue resumes from its safe checkpoint.
Put the Mac to sleep during an overdue External Sync schedule, wake it, and verify exactly one catch-up attempt.
Use one user-approved Plaud test recording with the official Plaud CLI signed in and confirm that the import is deduplicated and independently retryable.
Use one non-sensitive synthetic transcript with the signed-in Claude Code CLI and confirm the boundary output schema, timeout behavior, and no-tool behavior.
Verify the sensitive category with process observation and confirm that Claude Code is not launched.
Open the local MCP through stdio and confirm date, speaker, and keyword search plus meeting and speaker reads.
Check menu bar persistence after closing the main window, Login Item behavior from an app bundle, and Cmd+Q termination.
Review the final diagnostics export and confirm it has no transcript, audio, profile, token, or absolute home path.

## Evidence handling

Keep raw recordings, transcripts, browser profile data, session values, and voice embeddings outside Git.
Capture only redacted test command output and screenshots with synthetic meeting content.
Record the device, macOS version, configured storage root category, duration, pass or fail result, and next action for every human check.
