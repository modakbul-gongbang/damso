import AppKit
import SwiftUI

/// Menu-bar popover: the shared panel card plus resident-app controls
/// (open app, launch at login, quit). Mirrors the live detection session
/// when one exists; otherwise the card's idle state offers manual recording
/// through the same pipeline as the main window's Record button.
struct MeetingMenuBarCard: View {
    @ObservedObject var workspace: MeetingWorkspaceController
    @ObservedObject var detection: MeetingDetectionCoordinator
    @ObservedObject var panelModel: MeetingPromptPanelModel
    @ObservedObject var loginItem: LoginItemController
    @ObservedObject var externalSync: ExternalSyncController
    /// Re-activates and positions an already-open main window; window
    /// creation itself goes through the scene-provided openWindow action.
    var openMainWindow: () -> Void

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingPanelCardView(
                phase: effectivePhase,
                actions: effectiveActions,
                startDisabled: workspace.isCaptureStartPending,
                failureMessage: failureMessage,
                onOpenApp: {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                    openMainWindow()
                }
            )
            footer
        }
        .onAppear { loginItem.refresh() }
    }

    /// Detection session first; a manual recording (detection machine idle)
    /// still renders as the recording card so it can be stopped from here.
    private var effectivePhase: MeetingPromptPanelPhase? {
        if let phase = panelModel.phase { return phase }
        if workspace.isRecording {
            return .recording(
                startedAt: workspace.recordingStartedAt ?? Date(),
                participantCount: nil,
                showPairingHint: false
            )
        }
        return nil
    }

    /// Detection phases route through the session state machine (grace and
    /// cutoff apply); manual start/stop uses the main window's primary action.
    /// Settings always opens through the scene-provided action, which works
    /// reliably from the popover where the AppKit selector path may not.
    private var effectiveActions: MeetingPromptPanelActions {
        var actions: MeetingPromptPanelActions
        if panelModel.phase != nil {
            actions = panelModel.actions
        } else {
            actions = MeetingPromptPanelActions()
            actions.record = { [weak workspace] in
                Task { await workspace?.performPrimaryAction() }
            }
            actions.stop = actions.record
        }
        actions.openCaptureSettings = {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        return actions
    }

    private var failureMessage: String? {
        if case .failed = workspace.state { return workspace.recoveryAction }
        return nil
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: DamsoTokens.spacingXS) {
            Rectangle()
                .fill(DamsoTokens.hairline)
                .frame(height: 1)
            if let status = detection.statusLine {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(DamsoTokens.inkSecondary)
                    .padding(.horizontal, DamsoTokens.spacing)
            }
            // Re-login badge for external sync (R9): visible here even when
            // the main window is closed, and clickable straight to Settings.
            if let syncStatus = externalSync.statusLine {
                Button {
                    SettingsOpener.open()
                } label: {
                    Label(syncStatus, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(DamsoTokens.warning)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, DamsoTokens.spacing)
            }
            if let message = loginItem.configurationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(DamsoTokens.inkSecondary)
                    .padding(.horizontal, DamsoTokens.spacing)
            }
            HStack {
                Toggle(Loc.tr("Launch at Login"), isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabledSafely($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.caption)
                .disabled(!loginItem.canConfigure)
                Spacer()
                Button(Loc.tr("Quit Damso")) {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(DamsoTokens.inkSecondary)
                .keyboardShortcut("q")
            }
            .padding(.horizontal, DamsoTokens.spacing)
            .padding(.bottom, DamsoTokens.spacingSM)
        }
    }
}
