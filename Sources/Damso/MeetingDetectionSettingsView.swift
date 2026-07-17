import SwiftUI

/// Pane for the meeting detection daemon (R8): detection on/off,
/// participant capture on/off, and the chromux live-pairing status with
/// setup guidance. Both toggles default to on; turning capture off never
/// affects recording itself.
struct MeetingDetectionSettingsView: View {
    @AppStorage(MeetingDetectionPreferences.detectionEnabledKey) private var detectionEnabled = true
    @AppStorage(MeetingDetectionPreferences.participantCaptureEnabledKey) private var captureEnabled = true
    @State private var pairingState: PairingState = .checking

    private enum PairingState: Equatable {
        case checking
        case paired(tabCount: Int)
        case unpaired
    }

    var body: some View {
        SettingsGroup(title: Loc.tr("Meeting detection")) {
            SettingsRow(
                title: Loc.tr("Detect meetings and offer to record"),
                subtitle: Loc.tr("Watches for Zoom app meetings and Meet/Zoom tabs in Chrome, Dia, Arc, and Safari via microphone activity. Nothing is recorded until you press Record.")
            ) {
                Toggle("", isOn: $detectionEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }

        SettingsGroup(title: Loc.tr("Participant capture")) {
            SettingsRow(
                title: Loc.tr("Collect participant names while recording"),
                subtitle: Loc.tr("During an approved recording of a chromux-paired browser meeting, participant names and Meet active-speaker samples are collected into the meeting folder. Names never leave this Mac.")
            ) {
                Toggle("", isOn: $captureEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!detectionEnabled)
            }
        }

        SettingsGroup(title: Loc.tr("Chrome pairing")) {
            SettingsRow(title: pairingText) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(pairingColor)
                        .frame(width: 8, height: 8)
                    Button(Loc.tr("Check again")) {
                        pairingState = .checking
                        Task { await refreshPairing() }
                    }
                    .disabled(pairingState == .checking)
                }
            }
            .accessibilityElement(children: .combine)
            if case .unpaired = pairingState {
                SettingsFootnote(text: Loc.tr("Meeting detection and recording work without pairing (Chrome tabs are read via Automation permission). Pairing the chromux extension only adds participant names and Meet speaker samples: run `chromux pair` in a terminal, approve the extension, then check again."))
            }
        }
        .task { await refreshPairing() }
    }

    private var pairingColor: Color {
        switch pairingState {
        case .checking: DamsoTokens.inkSecondary
        case .paired: DamsoTokens.success
        case .unpaired: DamsoTokens.warning
        }
    }

    private var pairingText: String {
        switch pairingState {
        case .checking: Loc.tr("Checking chromux pairing...")
        case .paired(let count): String(format: Loc.tr("Paired - %d Chrome tabs visible"), count)
        case .unpaired: Loc.tr("Not paired")
        }
    }

    private func refreshPairing() async {
        // Passive status only: checking pairing from Settings must never
        // launch the user's Chrome. Tabs are listed only once the relay is
        // already connected, which is a no-launch operation.
        guard await ChromuxLivePairing.status().relayConnected else {
            pairingState = .unpaired
            return
        }
        let data = await MeetingProbeSubprocess.run(arguments: ["chromux", "tabs", "--json"], timeoutSeconds: 5)
        if let data, let tabs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            pairingState = .paired(tabCount: tabs.count)
        } else {
            pairingState = .unpaired
        }
    }
}
