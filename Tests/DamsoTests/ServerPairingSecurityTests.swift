import Foundation
import Testing
@testable import Damso

/// R5/AC5: the pairing warning's whole job is to tell a private network from
/// a public one, and its most dangerous failure is the false positive - the
/// operator's own Tailscale address sits in the CGNAT range (100.64/10),
/// which is *not* classic RFC1918 space, so a naive "is this 10/172/192"
/// check would warn on exactly the trusted setup the feature exists to bless.
@Suite
struct TrustedNetworkAddressTests {
    @Test
    func privateAndTailnetAddressesAreTrusted() {
        for address in [
            "10.0.0.1", "10.255.255.254",
            "172.16.0.1", "172.31.255.254",
            "192.168.1.10",
            "100.64.0.1", "100.100.100.100", "100.127.255.254",
            "127.0.0.1", "localhost", "::1", "[::1]",
            // Synthetic tailnet name. What matters is the `.ts.net` suffix and
            // that matching is case-insensitive, so a real one would only
            // publish someone's network topology for nothing.
            "example-mac-mini.tailnet-example.ts.net", "MINI.TS.NET"
        ] {
            #expect(TrustedNetworkAddress.isTrusted(address), "expected \(address) to be trusted")
        }
    }

    @Test
    func publicAddressesAndOrdinaryDomainsAreNotTrusted() {
        for address in [
            "8.8.8.8", "1.1.1.1",
            "172.15.0.1", "172.32.0.1",   // just outside RFC1918's 172.16/12
            "100.63.255.254", "100.128.0.1", // just outside CGNAT 100.64/10
            "192.169.1.1",
            "damso.example.com", "ts.net.example.com"
        ] {
            #expect(!TrustedNetworkAddress.isTrusted(address), "expected \(address) to be untrusted")
        }
    }

    @Test
    func theWarningAppearsOnlyForAnUntrustedAddress() async {
        let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        let controller = await RemoteExecutionSettingsController(configuration: configuration)

        await MainActor.run { controller.host = "100.100.100.100" }
        #expect(await controller.untrustedNetworkWarning == nil)

        await MainActor.run { controller.host = "203.0.113.9" }
        #expect(await controller.untrustedNetworkWarning != nil)

        // An empty field is not yet a claim about anything, so it must not
        // pre-emptively accuse the operator of a bad address.
        await MainActor.run { controller.host = "  " }
        #expect(await controller.untrustedNetworkWarning == nil)
    }
}

/// R8/AC6/D-09: an upgraded install that still holds an HTTPS-era pairing has
/// a token in a Keychain the app no longer reads, pointed at a server that no
/// longer serves TLS. It must say so instead of failing silently.
@Suite
struct LegacyPairingDetectionTests {
    @Test
    func aStoredCertificateFingerprintTriggersTheRepairNotice() async {
        let preferences = InMemoryConfigurationPreferences()
        preferences.setString("mini.local", forKey: ServerConnectionConfiguration.remoteHostKey)
        preferences.setString("deadbeef", forKey: ServerConnectionConfiguration.legacyRemoteFingerprintKey)
        let configuration = ServerConnectionConfiguration(preferences: preferences, tokenStore: InMemoryServerTokenStore())

        #expect(configuration.legacyPairingDetected)
        let controller = await RemoteExecutionSettingsController(configuration: configuration)
        #expect(await controller.legacyHTTPSPairingDetected)
    }

    @Test
    func afterANewPairingTheNoticeIsGone() async throws {
        let preferences = InMemoryConfigurationPreferences()
        preferences.setString("mini.local", forKey: ServerConnectionConfiguration.remoteHostKey)
        preferences.setString("deadbeef", forKey: ServerConnectionConfiguration.legacyRemoteFingerprintKey)
        let configuration = ServerConnectionConfiguration(preferences: preferences, tokenStore: InMemoryServerTokenStore())

        try configuration.configureRemote(host: "100.64.0.5", port: 8787, token: "fresh-token", storeRootPath: "/tmp/store")

        #expect(!configuration.legacyPairingDetected)
        guard case .remote(_, _, let token) = configuration.mode else {
            Issue.record("expected .remote after pairing")
            return
        }
        #expect(token == "fresh-token")
    }

    @Test
    func aPairingWithNoFingerprintIsNotFlagged() {
        let preferences = InMemoryConfigurationPreferences()
        preferences.setString("100.64.0.5", forKey: ServerConnectionConfiguration.remoteHostKey)
        let configuration = ServerConnectionConfiguration(preferences: preferences, tokenStore: InMemoryServerTokenStore())

        #expect(!configuration.legacyPairingDetected)
    }
}

/// R4/D-07: the token moved out of the Keychain into a file, so the file's
/// own permissions are now the whole protection - a world-readable token file
/// would silently hand the store to every process on this Mac.
@Suite
struct FileServerTokenStoreTests {
    @Test
    func theTokenIsWrittenReadBackAndDeletedAsAPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("damso-token-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileServerTokenStore(directory: directory)

        #expect(try store.read() == nil)

        try store.write("secret-token")
        #expect(try store.read() == "secret-token")

        let path = directory.appendingPathComponent("server-token").path
        let permissions = try #require(
            try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.int16Value == 0o600)

        // A re-pair overwrites in place; the replacement must not come back
        // with the temporary file's default permissions.
        try store.write("second-token")
        #expect(try store.read() == "second-token")
        let afterRewrite = try #require(
            try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        )
        #expect(afterRewrite.int16Value == 0o600)

        try store.delete()
        #expect(try store.read() == nil)
        try store.delete()  // deleting an absent token is not an error
    }
}
