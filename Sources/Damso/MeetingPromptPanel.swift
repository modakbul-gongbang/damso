import AppKit
import SwiftUI

/// What the floating panel is currently showing. Purely presentational; the
/// detection coordinator derives it from the session state machine.
enum MeetingPromptPanelPhase: Equatable {
    /// Meeting detected, recording not started. Proposals always use the same
    /// full card; [무시] hides the panel instead of changing its shape.
    case proposal(titleHint: String, app: MeetingSourceApp)
    /// Recording in progress: elapsed time and the live participant count when
    /// participant capture is paired. Capture is an opt-in add-on, so its
    /// absence is silent here - the card never advertises it.
    case recording(startedAt: Date, participantCount: Int?)
    /// A sub-cutoff recording ended: discard by default, keep as rescue.
    case shortConfirm(durationSeconds: Int)
}

/// User actions the panel can emit. Wired by the detection coordinator.
struct MeetingPromptPanelActions {
    var record: () -> Void = {}
    var ignore: () -> Void = {}
    var stop: () -> Void = {}
    var discard: () -> Void = {}
    var keep: () -> Void = {}
    var openCaptureSettings: () -> Void = {}
}

@MainActor
final class MeetingPromptPanelModel: ObservableObject {
    @Published var phase: MeetingPromptPanelPhase?
    /// The speaker count the user plans for the meeting being proposed. The
    /// floating panel has no workspace reference, so the coordinator seeds this
    /// when a proposal appears and reads it back when recording is approved.
    @Published var plannedSpeakerCount = SpeakerPlan.defaultCount
    var actions = MeetingPromptPanelActions()
}

// MARK: - Panel window controller

/// Owns the non-activating floating NSPanel at the top-right of the active
/// screen. Never steals focus from the meeting; hidden entirely when no
/// session is live.
@MainActor
final class MeetingPromptPanelController {
    let model = MeetingPromptPanelModel()
    private var panel: NSPanel?

    func render(phase: MeetingPromptPanelPhase?) {
        model.phase = phase
        guard phase != nil else {
            panel?.orderOut(nil)
            return
        }
        let panel = ensurePanel()
        positionTopRight(panel)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let created = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        created.isFloatingPanel = true
        created.level = .statusBar
        created.backgroundColor = .clear
        created.isOpaque = false
        created.hasShadow = true
        created.hidesOnDeactivate = false
        created.isMovableByWindowBackground = true
        created.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        created.contentView = NSHostingView(rootView: MeetingPromptPanelView(model: model))
        panel = created
        return created
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let hosting = panel.contentView as? NSHostingView<MeetingPromptPanelView> else { return }
        let size = hosting.fittingSize
        panel.setContentSize(size)
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let margin = DamsoTokens.spacing
        let origin = NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin
        )
        panel.setFrameOrigin(origin)
    }
}

// MARK: - Floating panel content

struct MeetingPromptPanelView: View {
    @ObservedObject var model: MeetingPromptPanelModel

    var body: some View {
        Group {
            switch model.phase {
            case .none:
                EmptyView()
            case .some(let phase):
                MeetingPanelCardView(
                    phase: phase,
                    actions: model.actions,
                    speakerCount: $model.plannedSpeakerCount
                )
                .background(panelChrome)
            }
        }
        .padding(4)
        .fixedSize()
    }

    private var panelChrome: some View {
        RoundedRectangle(cornerRadius: DamsoTokens.radius)
            .fill(DamsoTokens.canvas)
            .overlay(
                RoundedRectangle(cornerRadius: DamsoTokens.radius)
                    .strokeBorder(DamsoTokens.hairline, lineWidth: 1)
            )
    }

}

// MARK: - Shared card

/// The card body shared by the floating detection panel and the menu-bar
/// popover: header with app mark and quick actions, plus phase-specific
/// content. A nil phase is the menu-bar idle state offering manual recording.
///
/// The card deliberately says nothing about chromux. Participant-name capture
/// is an optional add-on that only changes whether names accompany a recording,
/// so probing its pairing here made every idle and proposal card run a
/// subprocess and nag about a dependency the app does not need. Setting it up
/// lives in the capture settings screen instead.
struct MeetingPanelCardView: View {
    var phase: MeetingPromptPanelPhase?
    var actions: MeetingPromptPanelActions
    var startDisabled = false
    var failureMessage: String?
    var onOpenApp: (() -> Void)?
    /// Pre-recording speaker-count plan, shown above the start button on both
    /// the idle card and the detection proposal. Diarization needs an oracle
    /// count and the auto-estimator is unreliable, so the moment a recording is
    /// offered is the moment to collect it - a detected meeting is exactly when
    /// the user knows how many people are on the call.
    var speakerCount: Binding<Int>?
    /// Optional participant-name plan, paired with `speakerCount` on the
    /// menu-bar idle card. Names picked here prefill the speaker count and
    /// feed the transcription hint, same as the main window's plan field.
    var participants: Binding<[String]>?
    var knownPeople: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DamsoTokens.spacing)
                .padding(.vertical, DamsoTokens.spacingSM)
            Rectangle()
                .fill(DamsoTokens.hairline)
                .frame(height: 1)
            content
                .padding(DamsoTokens.spacing)
        }
        .frame(width: 300, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: DamsoTokens.spacingXS) {
            Image(systemName: "waveform.and.person.filled")
                .font(.callout)
                .foregroundStyle(DamsoTokens.accent)
            Text(verbatim: "Damso")
                .font(.headline)
                .foregroundStyle(DamsoTokens.ink)
            Spacer()
            if let onOpenApp {
                Button(action: onOpenApp) {
                    Image(systemName: "folder")
                }
                .buttonStyle(PanelIconButtonStyle())
                .accessibilityLabel(Loc.tr("Open Damso"))
            }
            Button(action: actions.openCaptureSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(PanelIconButtonStyle())
            .accessibilityLabel(Loc.tr("Settings"))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .none:
            idleBody
        case .proposal(let titleHint, let app):
            proposalBody(titleHint: titleHint, app: app)
        case .recording(let startedAt, let participantCount):
            recordingBody(startedAt: startedAt, participantCount: participantCount)
        case .shortConfirm(let durationSeconds):
            shortConfirmBody(durationSeconds: durationSeconds)
        }
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: DamsoTokens.spacingSM) {
            if let speakerCount {
                SpeakerCountStepper(count: speakerCount)
            }
            if let participants {
                ParticipantPlanField(participants: participants, knownPeople: knownPeople)
            }
            Button {
                actions.record()
            } label: {
                Label(Loc.tr("Start recording"), systemImage: "record.circle")
            }
            .buttonStyle(PanelCardButtonStyle(rank: .primary))
            .disabled(startDisabled)
            if let failureMessage {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(DamsoTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func proposalBody(titleHint: String, app: MeetingSourceApp) -> some View {
        VStack(alignment: .leading, spacing: DamsoTokens.spacingSM) {
            HStack(alignment: .top, spacing: DamsoTokens.spacingXS) {
                Image(systemName: app == .zoomApp ? "video.fill" : "globe")
                    .font(.body)
                    .foregroundStyle(DamsoTokens.accent)
                    .accessibilityLabel(app.displayName)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Loc.tr("Meeting detected"))
                        .font(.damsoEyebrow)
                        .foregroundStyle(DamsoTokens.inkSecondary)
                    Text(titleHint)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(DamsoTokens.ink)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            if let speakerCount {
                SpeakerCountStepper(count: speakerCount)
            }
            Button {
                actions.record()
            } label: {
                Label(Loc.tr("Start recording"), systemImage: "record.circle")
            }
            .buttonStyle(PanelCardButtonStyle(rank: .primary))
            Button(Loc.tr("Ignore")) { actions.ignore() }
                .buttonStyle(PanelCardButtonStyle(rank: .secondary))
        }
    }

    private func recordingBody(startedAt: Date, participantCount: Int?) -> some View {
        VStack(alignment: .leading, spacing: DamsoTokens.spacingSM) {
            HStack(spacing: DamsoTokens.spacingXS) {
                Image(systemName: "record.circle.fill")
                    .font(.body)
                    .foregroundStyle(DamsoTokens.critical)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(meetingPanelElapsedText(from: startedAt, to: context.date))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(DamsoTokens.ink)
                }
                Spacer()
                if let participantCount {
                    Label(String(format: Loc.tr("%d participants"), participantCount), systemImage: "person.2")
                        .font(.damsoMonoCaption)
                        .foregroundStyle(DamsoTokens.inkSecondary)
                }
            }
            Button(Loc.tr("Stop")) { actions.stop() }
                .buttonStyle(PanelCardButtonStyle(rank: .critical))
        }
    }

    private func shortConfirmBody(durationSeconds: Int) -> some View {
        VStack(alignment: .leading, spacing: DamsoTokens.spacingSM) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Loc.tr("Short recording - discard it?"))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(DamsoTokens.ink)
                Text(meetingPanelElapsedText(seconds: durationSeconds))
                    .font(.damsoMonoCaption)
                    .foregroundStyle(DamsoTokens.inkSecondary)
            }
            HStack(spacing: DamsoTokens.spacingXS) {
                Button(Loc.tr("Discard")) { actions.discard() }
                    .buttonStyle(PanelCardButtonStyle(rank: .primary))
                Button(Loc.tr("Keep anyway")) { actions.keep() }
                    .buttonStyle(PanelCardButtonStyle(rank: .secondary))
            }
        }
    }

}

func meetingPanelElapsedText(from start: Date, to now: Date) -> String {
    meetingPanelElapsedText(seconds: max(0, Int(now.timeIntervalSince(start))))
}

func meetingPanelElapsedText(seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let secs = seconds % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%d:%02d", minutes, secs)
}

// MARK: - Button styles

/// Full-width card action button: solid ink for the primary action, outline
/// for the alternative, solid critical for stop.
struct PanelCardButtonStyle: ButtonStyle {
    enum Rank {
        case primary
        case secondary
        case critical
    }

    var rank: Rank

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .foregroundStyle(foreground)
            .background(RoundedRectangle(cornerRadius: 10).fill(background))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(DamsoTokens.hairline, lineWidth: rank == .secondary ? 1 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }

    private var foreground: Color {
        switch rank {
        case .primary: DamsoTokens.canvas
        case .secondary: DamsoTokens.ink
        case .critical: DamsoTokens.canvas
        }
    }

    private var background: Color {
        switch rank {
        case .primary: DamsoTokens.ink
        case .secondary: .clear
        case .critical: DamsoTokens.critical
        }
    }
}

/// Bare icon button for the card header.
struct PanelIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .foregroundStyle(DamsoTokens.inkSecondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
