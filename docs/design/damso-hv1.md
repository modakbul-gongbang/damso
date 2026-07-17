# Meeting Hub HV1 Design Proposal

## Design Read

Personal macOS meeting workbench for one daily user, with a calm high-trust operational language grounded in Apple Human Interface Guidelines.

## Dials

- Design variance: 3. The hierarchy is predictable and keyboard-friendly.
- Motion intensity: 2. State changes are immediate and avoid decorative animation.
- Visual density: 5. A meeting exposes enough status to make the next action obvious without becoming a control room.

## Token Proposal

| Token | Value | Use |
| --- | --- | --- |
| Accent | `#0A665E` light / `#59D4C7` dark | Primary actions, selected state, non-critical source indicators |
| Attention | `#853D05` light / `#FFB35E` dark | Session expiry and recoverable warnings |
| Critical | `#9E1A21` light / `#FF8A85` dark | Live recording and destructive-looking stop state |
| Success | `#056B3B` light / `#66D699` dark | Completed processing stages |
| Corner radius | 8 / 12 pt | Controls / grouped content |
| Spacing | 8 pt grid | All primary layout spacing |
| Motion | Native system transitions only | Respects reduced motion and never hides state changes |

The color system uses one product accent and semantic colors only for real state.
Each semantic foreground color has separate light and dark appearance values and is regression-tested at 4.5:1 or higher against its conservative system surface.
Text uses system typography and dynamic type.
The app follows the system appearance instead of mixing light and dark themes per view.

## Main Window

- Three-column macOS layout: Library and sources, meeting list, selected meeting detail.
- A persistent sidebar action starts an empty-hint recording immediately.
- The active capture row explains that both local audio sources are retained locally.
- Meeting rows identify source, timestamp, duration and the single next status.

## Speaker Card

- Each unresolved speaker shows duration, segment count and truthful excerpt availability.
- Actions are Play excerpt, Choose existing, Create person and Skip.
- The card makes speaker resolution an explicit decision. It never assigns or merges people automatically.

## Plaud Session Expiry

- An inline amber notice says that local work is safe and that a sign-in is needed for the next scheduled sync.
- The recovery action is presented where the failure occurs instead of as an unexplained global alert.

## Core States

| State | Treatment |
| --- | --- |
| Empty library | A short explanation and a single Record now action |
| Recording | Red semantic status, visible source state and a clear Stop recording action |
| Processing | Four named pipeline stages with complete and pending state |
| Partial success | Completed meetings remain visible. Failed source files retain a retryable error state. |
| Permission denied | Explain the missing capability, why it is needed and the system-settings recovery action. |
| Dependency missing | Identify the runtime component and provide a diagnosis action. |
| Storage unsafe | Prevent recording or processing before writing and state why no fallback location is used. |

## Accessibility And Interaction

- The primary capture action, list selection, speaker actions and retry actions have explicit VoiceOver labels and hints.
- Status is never represented by color alone.
- Controls are reachable by keyboard and use system focus rendering.
- The proposed token contrast is intended to meet 4.5:1 or higher for text and icons against their surface.

## Preview Scope

`swift run Damso` opens the static validation shell at `Sources/Damso/DesignReviewWindow.swift`.
It intentionally does not access audio, Plaud, a filesystem store, Chrome, a CLI or personal data.

## Requested HV1 Decision

Approve this token direction and the five reviewed surfaces: main window, immediate recording, speaker card, Plaud expiry and core state language.
Changes after this gate should preserve the approved technical structure and accessibility requirements.
