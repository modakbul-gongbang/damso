import AppKit
import SwiftUI

/// Pane for External Sync: a provider list (Plaud is simply the first
/// entry) with connect/disconnect, the sync on/off toggle, and install
/// guidance when the provider's tooling is missing (R8, R10).
struct ExternalSyncSettingsView: View {
    @ObservedObject var sync: ExternalSyncController

    var body: some View {
        ForEach(sync.providerStates) { provider in
            SettingsGroup(title: provider.displayName) {
                providerContent(provider)
            }
        }
        .task { await sync.refreshAccountStates() }
    }

    @ViewBuilder
    private func providerContent(_ provider: ExternalSyncController.ProviderViewState) -> some View {
        switch provider.accountState {
        case .notInstalled(let guidance):
            VStack(alignment: .leading, spacing: 10) {
                Label(Loc.tr("The command-line tool for this service is not installed."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DamsoTokens.warning)
                Text(Loc.tr("Install Node 20 or newer, run the command below in Terminal, then check again."))
                    .font(.footnote)
                    .foregroundStyle(DamsoTokens.inkSecondary)
                HStack(spacing: DamsoTokens.spacing) {
                    Text(guidance)
                        .font(.damsoMonoCaption)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(DamsoTokens.surfaceSoft, in: RoundedRectangle(cornerRadius: DamsoTokens.radiusSM))
                    Spacer(minLength: 0)
                    Button(Loc.tr("Check again")) {
                        Task { await sync.refreshAccountStates() }
                    }
                }
            }
            .padding(.vertical, 14)

        case .needsLogin:
            SettingsRow(
                title: provider.needsRelogin
                    ? Loc.tr("The sign-in expired. Connect again to resume sync.")
                    : Loc.tr("Connect your account to import recordings automatically.")
            ) {
                connectButton(provider)
            }
            connectStatus(provider)

        case .connected:
            if provider.needsRelogin {
                SettingsRow(title: Loc.tr("The sign-in expired. Connect again to resume sync.")) {
                    connectButton(provider)
                }
                connectStatus(provider)
            } else {
                SettingsRow(
                    title: Loc.tr("Connected"),
                    subtitle: provider.lastSyncAt.map {
                        String(format: Loc.tr("Last synced %@"), $0.formatted(date: .abbreviated, time: .shortened))
                    }
                ) {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(DamsoTokens.success)
                        Button(Loc.tr("Disconnect"), role: .destructive) {
                            sync.disconnect(providerID: provider.id)
                        }
                    }
                }
                SettingsRow(
                    title: Loc.tr("Sync automatically every hour"),
                    subtitle: Loc.tr("New recordings from the last 7 days are imported and processed locally. Nothing is uploaded.")
                ) {
                    Toggle("", isOn: Binding(
                        get: { provider.syncEnabled },
                        set: { sync.setSyncEnabled($0, providerID: provider.id) }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                }
            }

        case .error(let code):
            SettingsRow(title: String(format: Loc.tr("The service is unavailable: %@"), code)) {
                Button(Loc.tr("Check again")) {
                    Task { await sync.refreshAccountStates() }
                }
            }
        }
    }

    @ViewBuilder
    private func connectButton(_ provider: ExternalSyncController.ProviderViewState) -> some View {
        Button {
            sync.connect(providerID: provider.id)
        } label: {
            if provider.isConnecting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(Loc.tr("Waiting for the browser sign-in..."))
                }
            } else {
                Text(Loc.tr("Connect"))
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(provider.isConnecting)
    }

    @ViewBuilder
    private func connectStatus(_ provider: ExternalSyncController.ProviderViewState) -> some View {
        if provider.isConnecting {
            SettingsFootnote(text: Loc.tr("A browser window opened for sign-in. This times out after 2 minutes."))
        }
        if let message = provider.connectMessage {
            Text(message)
                .font(.footnote)
                .foregroundStyle(DamsoTokens.warning)
                .padding(.vertical, DamsoTokens.spacingXS)
        }
    }
}

/// Opens the app's Settings scene from anywhere (sidebar rows, badges).
@MainActor
enum SettingsOpener {
    static func open() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
