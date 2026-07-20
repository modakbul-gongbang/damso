import AppKit
import SwiftUI

/// What the floating panel is currently showing. Purely presentational; the
/// detection coordinator derives it from the session state machine.
enum MeetingPromptPanelPhase: Equatable {
    /// Meeting detected, recording not started. Proposals always use the same
    /// full card; [무시] hides the panel instead of changing its shape.
    case proposal(titleHint: String, app: MeetingSourceApp)
    /// Recording in progress: elapsed time, live participant count, and the
    /// pairing hint when chromux capture is unavailable.
    case recording(startedAt: Date, participantCount: Int?, showPairingHint: Bool)
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
                MeetingPanelCardView(phase: phase, actions: model.actions)
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

/// chromux pairing readout shown on the card's idle and proposal states.
enum MeetingPanelPairingStatus: Equatable {
    case checking
    case paired(tabCount: Int)
    case unpaired
}

/// The card body shared by the floating detection panel and the menu-bar
/// popover: header with app mark and quick actions, phase-specific content,
/// and the participant-capture pairing row. A nil phase is the menu-bar idle
/// state offering manual recording.
struct MeetingPanelCardView: View {
    var phase: MeetingPromptPanelPhase?
    var actions: MeetingPromptPanelActions
    var startDisabled = false
    var failureMessage: String?
    var onOpenApp: (() -> Void)?

    @State private var pairing = MeetingPanelPairingStatus.checking

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
        case .recording(let startedAt, let participantCount, let showPairingHint):
            recordingBody(startedAt: startedAt, participantCount: participantCount, showPairingHint: showPairingHint)
        case .shortConfirm(let durationSeconds):
            shortConfirmBody(durationSeconds: durationSeconds)
        }
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: DamsoTokens.spacingSM) {
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
            pairingRow
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
            Button {
                actions.record()
            } label: {
                Label(Loc.tr("Start recording"), systemImage: "record.circle")
            }
            .buttonStyle(PanelCardButtonStyle(rank: .primary))
            Button(Loc.tr("Ignore")) { actions.ignore() }
                .buttonStyle(PanelCardButtonStyle(rank: .secondary))
            pairingRow
        }
    }

    private func recordingBody(startedAt: Date, participantCount: Int?, showPairingHint: Bool) -> some View {
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
            if showPairingHint {
                Button {
                    actions.openCaptureSettings()
                } label: {
                    Label(Loc.tr("Set up participant capture"), systemImage: "arrow.right.circle")
                        .font(.damsoEyebrow)
                        .foregroundStyle(DamsoTokens.accent)
                }
                .buttonStyle(.plain)
            }
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

    /// Idle and proposal only: whether participant capture will work for the
    /// next recording. Recording itself never depends on pairing.
    private var pairingRow: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(pairingColor)
                .frame(width: 6, height: 6)
            switch pairing {
            case .checking:
                Text(Loc.tr("Checking chromux pairing..."))
                    .font(.caption)
                    .foregroundStyle(DamsoTokens.inkSecondary)
            case .paired:
                Text(Loc.tr("Participant capture ready"))
                    .font(.caption)
                    .foregroundStyle(DamsoTokens.inkSecondary)
            case .unpaired:
                Button(Loc.tr("Set up participant capture")) { actions.openCaptureSettings() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(DamsoTokens.accent)
            }
        }
        .accessibilityElement(children: .combine)
        .task { await refreshPairing() }
    }

    private var pairingColor: Color {
        switch pairing {
        case .checking: DamsoTokens.inkSecondary
        case .paired: DamsoTokens.success
        case .unpaired: DamsoTokens.warning
        }
    }

    private func refreshPairing() async {
        // Passive status only: the card must never launch the user's Chrome
        // just because it was opened. Listing tabs is safe once the relay is
        // connected (chromux has nothing left to launch).
        guard await ChromuxLivePairing.status().relayConnected else {
            pairing = .unpaired
            return
        }
        let data = await MeetingProbeSubprocess.run(arguments: ["chromux", "tabs", "--json"], timeoutSeconds: 5)
        if let data, let tabs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            pairing = .paired(tabCount: tabs.count)
        } else {
            pairing = .unpaired
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
