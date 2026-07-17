import SwiftUI

struct ModelSetupSettingsView: View {
    @StateObject private var setup = LocalModelSetupController()
    @State private var showInstallationConfirmation = false

    var body: some View {
        Form {
            Section(Loc.tr("Local Processing Models")) {
                Label(setup.state.title, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
                    .accessibilityLabel(setup.state.title)

                Text(Loc.tr("Whisper large-v3 transcribes audio and Sherpa separates speakers on this Mac. Meeting audio, transcripts, Plaud sessions, and credentials are never uploaded during setup."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if case .failed(let code) = setup.state {
                    Text(String(format: Loc.tr("Setup stopped: %@. Check your network and local Python setup, then try again."), code))
                        .foregroundStyle(DamsoTokens.critical)
                }

                if case .unavailable(let code) = setup.state {
                    Text(String(format: Loc.tr("Not ready: %@."), code))
                        .foregroundStyle(DamsoTokens.warning)
                }

                HStack {
                    Button(Loc.tr("Check status")) {
                        setup.refresh()
                    }
                    .disabled(isBusy)

                    Button(Loc.tr("Install local models"), systemImage: "arrow.down.circle") {
                        showInstallationConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || isReady)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620)
        .task { setup.refresh() }
        .confirmationDialog(
            Loc.tr("Install local processing models?"),
            isPresented: $showInstallationConfirmation,
            titleVisibility: .visible
        ) {
            Button(Loc.tr("Download and install"), role: .none) {
                setup.install()
            }
        } message: {
            Text(Loc.tr("This user-initiated action downloads the required Python packages, Whisper large-v3, and Sherpa diarization models into a local Damso models folder. It does not upload meeting data."))
        }
    }

    private var isBusy: Bool {
        switch setup.state {
        case .checking, .installing:
            true
        default:
            false
        }
    }

    private var isReady: Bool {
        if case .ready = setup.state { return true }
        return false
    }

    private var statusSymbol: String {
        switch setup.state {
        case .ready:
            "checkmark.circle.fill"
        case .failed:
            "xmark.circle.fill"
        case .unavailable:
            "exclamationmark.triangle.fill"
        case .unchecked, .checking, .installing:
            "arrow.triangle.2.circlepath"
        }
    }

    private var statusColor: Color {
        switch setup.state {
        case .ready:
            DamsoTokens.success
        case .failed:
            DamsoTokens.critical
        case .unavailable:
            DamsoTokens.warning
        case .unchecked, .checking, .installing:
            DamsoTokens.accent
        }
    }
}
