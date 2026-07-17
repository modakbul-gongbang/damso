import SwiftUI

/// Settings for the meeting detection daemon (R8): detection on/off,
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
        Form {
            Section(Loc.tr("Meeting detection")) {
                Toggle(Loc.tr("Detect meetings and offer to record"), isOn: $detectionEnabled)
                Text(Loc.tr("Watches for Zoom app meetings and Meet/Zoom tabs in Chrome, Dia, Arc, and Safari via microphone activity. Nothing is recorded until you press Record."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(Loc.tr("Participant capture")) {
                Toggle(Loc.tr("Collect participant names while recording"), isOn: $captureEnabled)
                    .disabled(!detectionEnabled)
                Text(Loc.tr("During an approved recording of a chromux-paired browser meeting, participant names and Meet active-speaker samples are collected into the meeting folder. Names never leave this Mac."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(Loc.tr("Chrome pairing")) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(pairingColor)
                        .frame(width: 8, height: 8)
                    Text(pairingText)
                    Spacer()
                    Button(Loc.tr("Check again")) {
                        pairingState = .checking
                        Task { await refreshPairing() }
                    }
                    .disabled(pairingState == .checking)
                }
                .accessibilityElement(children: .combine)
                if case .unpaired = pairingState {
                    Text(Loc.tr("Participant capture uses the chromux extension in your Chrome. Run `chromux pair` in a terminal, approve the extension, then check again. Recording works fine without pairing."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
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
        let data = await MeetingProbeSubprocess.run(arguments: ["chromux", "tabs", "--json"], timeoutSeconds: 5)
        if let data, let tabs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            pairingState = .paired(tabCount: tabs.count)
        } else {
            pairingState = .unpaired
        }
    }
}
