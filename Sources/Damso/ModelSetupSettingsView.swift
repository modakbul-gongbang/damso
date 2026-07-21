import SwiftUI

struct ModelSetupSettingsView: View {
    @StateObject private var setup = LocalModelSetupController()
    @State private var showInstallationConfirmation = false

    var body: some View {
        SettingsGroup(title: Loc.tr("Local Processing Models")) {
            SettingsRow(
                title: setup.state.title,
                subtitle: Loc.tr("Whisper large-v3-turbo transcribes audio and Sherpa separates speakers on this Mac. Meeting audio, transcripts, Plaud sessions, and credentials are never uploaded during setup.")
            ) {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
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
            .accessibilityElement(children: .combine)

            if case .failed(let code) = setup.state {
                Text(String(format: Loc.tr("Setup stopped: %@. Check your network and local Python setup, then try again."), code))
                    .font(.footnote)
                    .foregroundStyle(DamsoTokens.critical)
                    .padding(.vertical, DamsoTokens.spacingXS)
            }

            if case .unavailable(let code) = setup.state {
                Text(String(format: Loc.tr("Not ready: %@."), code))
                    .font(.footnote)
                    .foregroundStyle(DamsoTokens.warning)
                    .padding(.vertical, DamsoTokens.spacingXS)
            }
        }
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
            Text(Loc.tr("This user-initiated action downloads the required Python packages, Whisper large-v3-turbo, and Sherpa diarization models into a local Damso models folder. It does not upload meeting data."))
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
