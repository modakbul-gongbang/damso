import Foundation

/// Where the canonical store's HTTP daemon lives for this app instance (R1,
/// D-05, D-08): a loopback port this app itself spawned, or a remote host
/// reached over plain HTTP with a bearer token. Replaces
/// `RemoteExecutionConfiguration`/`CommandExecutionMode` - the SSH-era
/// local/remote split at the *transport* layer (spawn locally vs. ssh-wrap)
/// collapses into one HTTP transport that only differs in bind address and
/// auth (D-05: "local 모드도 HTTP 루프백으로 동일 구조").
enum ServerConnectionMode: Equatable {
    /// This Mac's own daemon, reached over 127.0.0.1. No token - the client
    /// and server are the same trust boundary already (D-08).
    case local(port: Int)
    /// A daemon on another Mac, reached over plain HTTP with a bearer token.
    /// Transport privacy is the operator's trusted private network (Tailscale
    /// or a trusted LAN), not app-level TLS (ADR 0003).
    case remote(host: String, port: Int, token: String)
}

/// Non-secret connection facts (host, port, remote store root) persist in
/// `UserDefaults`; the token lives in a 0600 file (`ServerTokenStoring`,
/// D-07) and never touches `UserDefaults`.
/// `@unchecked`: identical rationale to the SSH-era `RemoteExecutionConfiguration`
/// - `UserDefaults`/`InMemoryConfigurationPreferences` are safe for concurrent
/// read-only use, and this needs to cross into a `Task.detached` from
/// `@MainActor` code without a data-race error.
final class ServerConnectionConfiguration: @unchecked Sendable {
    static let remoteHostKey = "damso.server.remoteHost"
    static let remotePortKey = "damso.server.remotePort"
    static let remoteStoreRootPathKey = "damso.server.remoteStoreRootPath"
    /// Written only by pre-ADR-0003 builds, which pinned a certificate
    /// fingerprint at pairing time. Never written anymore; its presence is
    /// exactly the signal that this Mac holds a pairing whose token now lives
    /// in the Keychain the app no longer reads, against a server that no
    /// longer speaks HTTPS - so the app must ask for a re-pair (R8).
    static let legacyRemoteFingerprintKey = "damso.server.remoteFingerprint"
    /// Written by `LocalServerLifecycle` after a successful spawn, since a
    /// port conflict silently reselects (D-22) - this is the only place the
    /// chosen port is recorded for the HTTP client to read.
    static let localPortKey = "damso.server.localPort"

    static let defaultPort = 8787

    private let preferences: ConfigurationPreferences
    private let tokenStore: ServerTokenStoring

    init(preferences: ConfigurationPreferences = UserDefaults.standard, tokenStore: ServerTokenStoring = FileServerTokenStore()) {
        self.preferences = preferences
        self.tokenStore = tokenStore
    }

    var mode: ServerConnectionMode {
        guard let host = preferences.string(forKey: Self.remoteHostKey), !host.isEmpty else {
            let port = preferences.string(forKey: Self.localPortKey).flatMap(Int.init) ?? Self.defaultPort
            return .local(port: port)
        }
        let port = preferences.string(forKey: Self.remotePortKey).flatMap(Int.init) ?? Self.defaultPort
        let token = (try? tokenStore.read()) ?? nil
        return .remote(host: host, port: port, token: token ?? "")
    }

    /// A pairing made by a pre-ADR-0003 build: HTTPS with a pinned
    /// certificate and a Keychain-stored token. Nothing about it still works,
    /// and there is deliberately no in-place upgrade - the operator re-runs
    /// `make install-server` and pairs again (R8, D-09).
    var legacyPairingDetected: Bool {
        let fingerprint = preferences.string(forKey: Self.legacyRemoteFingerprintKey)
        return !(fingerprint?.isEmpty ?? true)
    }

    /// The daemon's own canonical store root, learned once during pairing and
    /// needed to build every `recording_directory`/`peoples_directory`
    /// request field - unchanged in spirit from the SSH-era
    /// `remoteStoreRootPath`.
    var remoteStoreRootPath: String? {
        guard case .remote = mode else { return nil }
        let path = preferences.string(forKey: Self.remoteStoreRootPathKey)
        return (path?.isEmpty ?? true) ? nil : path
    }

    func configureRemote(host: String, port: Int, token: String, storeRootPath: String) throws {
        preferences.setString(host, forKey: Self.remoteHostKey)
        preferences.setString(String(port), forKey: Self.remotePortKey)
        preferences.setString(storeRootPath, forKey: Self.remoteStoreRootPathKey)
        // A successful new pairing is what retires the old HTTPS-era one, so
        // the legacy marker (and the re-pair notice it drives) clears here.
        preferences.setString(nil, forKey: Self.legacyRemoteFingerprintKey)
        try tokenStore.write(token)
    }

    /// A fresh `make install-server` requires a full re-pairing, never an
    /// in-place credential update - clearing here is the only path back to
    /// `configureRemote`.
    func clearRemote() {
        preferences.setString(nil, forKey: Self.remoteHostKey)
        preferences.setString(nil, forKey: Self.remotePortKey)
        preferences.setString(nil, forKey: Self.legacyRemoteFingerprintKey)
        preferences.setString(nil, forKey: Self.remoteStoreRootPathKey)
        try? tokenStore.delete()
    }

    /// D-22: the local daemon's actual bound port, once known, so the HTTP
    /// client always dials the port that is actually listening rather than
    /// the fixed default that might have been in use.
    func recordLocalPort(_ port: Int) {
        preferences.setString(String(port), forKey: Self.localPortKey)
    }

    var baseURL: URL {
        switch mode {
        case .local(let port):
            URL(string: "http://127.0.0.1:\(port)")!
        case .remote(let host, let port, _):
            URL(string: "http://\(host):\(port)")!
        }
    }
}
