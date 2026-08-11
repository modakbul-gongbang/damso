import SwiftUI

/// D-08/UX-01: pairs this Mac with a server daemon over plain HTTP on a
/// trusted private network (ADR 0003). Local mode (the default) needs no
/// setup - the app spawns its own loopback daemon. Turning this on points
/// detection and recording at another Mac that already ran
/// `make install-server` and has an access token to share.
/// There is no remote provisioning step here anymore (D-11): the operator
/// runs `make install-server` themselves, and this pane only ever pairs
/// with an already-running daemon.
@MainActor
final class RemoteExecutionSettingsController: ObservableObject {
    enum CheckOutcome: Equatable {
        case idle
        case checking
        case unreachable(String)
        case versionMismatch(String)
        /// AC2: the address and protocol version check out, but the entered
        /// token was rejected (401) - distinct from `unreachable` so the user
        /// knows to re-check the token specifically, not the address.
        case invalidToken(String)
        /// The daemon answered and accepted the token; ready for the user to
        /// save. Carries the store root the daemon reports so it can be
        /// persisted alongside the pairing.
        case readyToPair(storeRoot: String)
        case paired
    }

    @Published var isRemoteEnabled = false
    @Published var host = ""
    @Published var port = String(ServerConnectionConfiguration.defaultPort)
    @Published var token = ""
    @Published private(set) var outcome: CheckOutcome = .idle
    @Published private(set) var requiresReopen = false
    @Published private(set) var oldSSHConfigurationDetected = false
    /// R8/D-09: a pairing made by a pre-ADR-0003 build (HTTPS + pinned
    /// certificate + Keychain token). Nothing about it still works and there
    /// is no in-place upgrade, so the pane asks for a re-pair.
    @Published private(set) var legacyHTTPSPairingDetected = false

    private let configuration: ServerConnectionConfiguration

    init(configuration: ServerConnectionConfiguration = ServerConnectionConfiguration()) {
        self.configuration = configuration
        load()
        oldSSHConfigurationDetected = Self.detectLegacySSHConfiguration()
        legacyHTTPSPairingDetected = configuration.legacyPairingDetected
    }

    var isBusy: Bool { outcome == .checking }

    var canSave: Bool {
        if case .readyToPair = outcome { return true }
        return false
    }

    /// D-08/D-11: the connection carries no transport encryption of its own,
    /// so an address outside a private range is worth calling out - but never
    /// blocking, since an operator can have a legitimate reason for one.
    var untrustedNetworkWarning: String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !TrustedNetworkAddress.isTrusted(trimmed) else { return nil }
        return Loc.tr("This address is not on a private network. Damso talks to a server Mac without its own encryption, so use it only over Tailscale, a VPN, or a LAN you trust.")
    }

    private func load() {
        switch configuration.mode {
        case .local:
            isRemoteEnabled = false
        case .remote(let savedHost, let savedPort, _):
            isRemoteEnabled = true
            host = savedHost
            port = String(savedPort)
        }
    }

    func setRemoteEnabled(_ enabled: Bool) {
        isRemoteEnabled = enabled
        guard !enabled else { return }
        outcome = .idle
        guard case .remote = configuration.mode else { return }
        configuration.clearRemote()
        requiresReopen = true
    }

    /// D-09: a fresh `make install-server` always means a full re-pairing
    /// with the new token, never an in-place credential update.
    func runCheck() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPort = Int(port) ?? ServerConnectionConfiguration.defaultPort
        guard !trimmedHost.isEmpty, !trimmedToken.isEmpty else {
            outcome = .unreachable(Loc.tr("Enter the server address and its access token."))
            return
        }
        outcome = .checking
        Task { await performCheck(host: trimmedHost, port: resolvedPort, token: trimmedToken) }
    }

    private func performCheck(host: String, port: Int, token: String) async {
        let versionResult = await Task.detached(priority: .userInitiated) {
            Result { try DamsoHTTPClient.probeVersion(host: host, port: port) }
        }.value
        guard let info = try? versionResult.get() else {
            outcome = .unreachable(Loc.tr("Could not reach a Damso server at this address."))
            return
        }
        guard info.protocolVersion == DamsoServerProtocol.version else {
            outcome = .versionMismatch(Loc.tr("This server needs a Damso update before pairing can continue."))
            return
        }
        // D-08/AC2: health/version stay unauthenticated (pairing has no
        // token yet), so this is the one preflight call actually made
        // against the token.
        let authorizedResult = await Task.detached(priority: .userInitiated) {
            Result { try DamsoHTTPClient.probeAuthorizedAccess(host: host, port: port, token: token) }
        }.value
        switch authorizedResult {
        case .success(.authorized(let storeRootPath)):
            outcome = .readyToPair(storeRoot: storeRootPath)
        case .success(.unauthorized):
            outcome = .invalidToken(Loc.tr("The access token is incorrect."))
        case .failure:
            outcome = .unreachable(Loc.tr("Could not reach a Damso server at this address."))
        }
    }

    func save() {
        guard case .readyToPair(let storeRoot) = outcome else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPort = Int(port) ?? ServerConnectionConfiguration.defaultPort
        do {
            try configuration.configureRemote(host: trimmedHost, port: resolvedPort, token: trimmedToken, storeRootPath: storeRoot)
        } catch {
            outcome = .unreachable(Loc.tr("The access token could not be saved."))
            return
        }
        legacyHTTPSPairingDetected = false
        outcome = .paired
        requiresReopen = true
    }

    /// UX-04: a leftover SSH-era preference means this install upgraded from
    /// the two-machine SSH split (ADR 0001) - never silently fall back to
    /// local mode with it still present, since that would start a fresh
    /// local store while the real data sits on the old server.
    private static func detectLegacySSHConfiguration() -> Bool {
        UserDefaults.standard.string(forKey: "damso.remoteExecution.host") != nil
    }
}

struct RemoteExecutionSettingsView: View {
    @StateObject private var settings = RemoteExecutionSettingsController()

    var body: some View {
        if settings.oldSSHConfigurationDetected {
            SettingsGroup(title: Loc.tr("Server Mac")) {
                SettingsFootnote(text: Loc.tr("This Mac has an old SSH-based server connection from before this update. It no longer works. Run `make install-server` on that Mac, then pair again below with its new address and access token."))
            }
        }

        if settings.legacyHTTPSPairingDetected {
            SettingsGroup(title: Loc.tr("Server Mac")) {
                SettingsFootnote(text: Loc.tr("This Mac was paired with a server that used its own certificate. Damso now connects over a trusted private network instead, so that pairing no longer works. Run `make install-server` on that Mac, then pair again below with its new access token."))
            }
        }

        SettingsGroup(title: Loc.tr("Server Mac")) {
            SettingsRow(
                title: Loc.tr("Use another Mac for storage and processing"),
                subtitle: Loc.tr("This Mac keeps detecting and recording meetings. The server holds every recording and runs transcription, so your laptop stays free and meetings finish processing even when it is closed.")
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isRemoteEnabled },
                    set: { settings.setRemoteEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(settings.isBusy)
            }

            if settings.isRemoteEnabled {
                SettingsRow(
                    title: Loc.tr("Server address"),
                    subtitle: Loc.tr("The server's hostname or IP address, and the port `make install-server` reported.")
                ) {
                    HStack(spacing: 8) {
                        TextField("", text: $settings.host, prompt: Text("192.168.1.10"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .disabled(settings.isBusy)
                        TextField("", text: $settings.port, prompt: Text("8787"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .disabled(settings.isBusy)
                    }
                }
                if let warning = settings.untrustedNetworkWarning {
                    SettingsFootnote(text: warning)
                }
                SettingsRow(
                    title: Loc.tr("Access token"),
                    subtitle: Loc.tr("Printed by `damso-server-credentials generate` on the server. Save it now - it is shown only once there.")
                ) {
                    SecureField("", text: $settings.token)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .disabled(settings.isBusy)
                }

                HStack(spacing: 12) {
                    if settings.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Spacer(minLength: 0)
                    Button(Loc.tr("Check")) {
                        settings.runCheck()
                    }
                    .disabled(settings.isBusy || settings.host.isEmpty || settings.token.isEmpty)
                    Button(Loc.tr("Save and use this Mac")) {
                        settings.save()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!settings.canSave)
                }
                .padding(.vertical, DamsoTokens.spacingXS)

                outcomeRow
            }
        }

        if settings.requiresReopen {
            SettingsFootnote(text: Loc.tr("Reopen Damso for this change to take effect. Existing data on either machine is untouched."))
        }
        if !settings.isRemoteEnabled {
            SettingsFootnote(text: Loc.tr("Leave this off to keep detection, recording, storage, and processing all on this Mac."))
        }
    }

    @ViewBuilder
    private var outcomeRow: some View {
        switch settings.outcome {
        case .idle, .checking:
            EmptyView()
        case .unreachable(let message):
            SettingsFootnote(text: message)
        case .versionMismatch(let message):
            SettingsFootnote(text: message)
        case .invalidToken(let message):
            SettingsFootnote(text: message)
        case .readyToPair:
            SettingsFootnote(text: Loc.tr("Connected and the access token works. Save to start using this server."))
        case .paired:
            SettingsFootnote(text: Loc.tr("Paired. Regenerating the server's token requires pairing again."))
        }
    }
}
