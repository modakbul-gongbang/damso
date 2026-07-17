import AppKit
import SwiftUI

/// Settings tab for External Sync: a provider list (Plaud is simply the
/// first entry) with connect/disconnect, the sync on/off toggle, and install
/// guidance when the provider's tooling is missing (R8, R10).
struct ExternalSyncSettingsView: View {
    @ObservedObject var sync: ExternalSyncController

    var body: some View {
        Form {
            ForEach(sync.providerStates) { provider in
                Section(provider.displayName) {
                    providerContent(provider)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620)
        .task { await sync.refreshAccountStates() }
    }

    @ViewBuilder
    private func providerContent(_ provider: ExternalSyncController.ProviderViewState) -> some View {
        switch provider.accountState {
        case .notInstalled(let guidance):
            Label(Loc.tr("The command-line tool for this service is not installed."), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DamsoTokens.warning)
            Text(Loc.tr("Install Node 20 or newer, run the command below in Terminal, then check again."))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(guidance)
                .font(.damsoMonoCaption)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(DamsoTokens.surfaceSoft, in: RoundedRectangle(cornerRadius: DamsoTokens.radiusSM))
            Button(Loc.tr("Check again")) {
                Task { await sync.refreshAccountStates() }
            }

        case .needsLogin:
            if provider.needsRelogin {
                Label(Loc.tr("The sign-in expired. Connect again to resume sync."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DamsoTokens.warning)
            } else {
                Text(Loc.tr("Connect your account to import recordings automatically."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            connectButton(provider)

        case .connected:
            if provider.needsRelogin {
                Label(Loc.tr("The sign-in expired. Connect again to resume sync."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DamsoTokens.warning)
                connectButton(provider)
            } else {
                Label(Loc.tr("Connected"), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(DamsoTokens.success)
                if let lastSyncAt = provider.lastSyncAt {
                    Text(String(format: Loc.tr("Last synced %@"), lastSyncAt.formatted(date: .abbreviated, time: .shortened)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Toggle(Loc.tr("Sync automatically every hour"), isOn: Binding(
                    get: { provider.syncEnabled },
                    set: { sync.setSyncEnabled($0, providerID: provider.id) }
                ))
                Text(Loc.tr("New recordings from the last 7 days are imported and processed locally. Nothing is uploaded."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(Loc.tr("Disconnect"), role: .destructive) {
                    sync.disconnect(providerID: provider.id)
                }
            }

        case .error(let code):
            Label(String(format: Loc.tr("The service is unavailable: %@"), code), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DamsoTokens.warning)
            Button(Loc.tr("Check again")) {
                Task { await sync.refreshAccountStates() }
            }
        }
    }

    @ViewBuilder
    private func connectButton(_ provider: ExternalSyncController.ProviderViewState) -> some View {
        HStack(spacing: 10) {
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
        if provider.isConnecting {
            Text(Loc.tr("A browser window opened for sign-in. This times out after 2 minutes."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if let message = provider.connectMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(DamsoTokens.warning)
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
