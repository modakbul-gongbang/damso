import Foundation
import Testing
@testable import Damso

/// AC2/T8: the pairing preflight ("Check") must distinguish an unreachable
/// address, a wrong token, and success - each with its own message - before
/// "Save" becomes available. These tests run Check against a real
/// `damso-server` process bound off loopback with a real generated token
/// (the same as `RemoteAuthTests` on the Python side), so a change to the
/// real version/token wire contract cannot pass silently against a mock.
/// Part of `LiveServerIntegrationTests` (declared in
/// `LiveServerIntegrationTests.swift`) - see that file's header for why this
/// is an `extension` rather than its own `@Suite`.
extension LiveServerIntegrationTests {
    @Test
    func checkWithTheCorrectTokenReachesReadyToPairAndSaveThenPairsTheConfiguration() async throws {
        let server = try LiveDamsoServerProcess.start(host: "0.0.0.0")
        defer { server.stop() }
        let credentials = try #require(server.credentials)

        let serverPort = server.port
        let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        let controller = await RemoteExecutionSettingsController(configuration: configuration)
        await MainActor.run {
            controller.host = "127.0.0.1"
            controller.port = String(serverPort)
            controller.token = credentials.token
        }

        await controller.runCheck()
        try await Self.waitUntilNotChecking(controller)

        let outcome = await controller.outcome
        guard case .readyToPair(let storeRoot) = outcome else {
            Issue.record("expected readyToPair, got \(outcome)")
            return
        }
        // The daemon's real canonical store root must survive pairing -
        // every record-mutation RPC (delete-record, update-record, ...)
        // builds its recording_directory from this value, and an empty
        // root silently breaks all of them in remote mode (found via a
        // real two-machine pairing test, not caught by any earlier test
        // here because none of them exercised a record-mutation call
        // after a real save()).
        #expect(!storeRoot.isEmpty)
        // `/var` vs. `/private/var` symlink normalization differs between
        // how this test builds its temp directory and how the server
        // reports its own resolved root, so compare the meaningful suffix
        // rather than the full path.
        #expect(storeRoot.hasSuffix(server.storeRoot.lastPathComponent))
        #expect(storeRoot.contains(server.storeRoot.deletingLastPathComponent().lastPathComponent))
        #expect(await controller.canSave)

        await controller.save()
        let saved = await controller.outcome
        #expect(saved == .paired)
        let mode = configuration.mode
        guard case .remote(let host, let port, let token) = mode else {
            Issue.record("expected .remote after save, got \(mode)")
            return
        }
        #expect(host == "127.0.0.1")
        #expect(port == server.port)
        #expect(token == credentials.token)
        #expect(configuration.remoteStoreRootPath?.hasSuffix(server.storeRoot.lastPathComponent) == true)
    }

    @Test
    func checkWithAWrongTokenReportsInvalidTokenDistinctFromUnreachable() async throws {
        let server = try LiveDamsoServerProcess.start(host: "0.0.0.0")
        defer { server.stop() }
        #expect(server.credentials != nil)
        let serverPort = server.port

        let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        let controller = await RemoteExecutionSettingsController(configuration: configuration)
        await MainActor.run {
            controller.host = "127.0.0.1"
            controller.port = String(serverPort)
            controller.token = "not-the-real-token"
        }

        await controller.runCheck()
        try await Self.waitUntilNotChecking(controller)

        let outcome = await controller.outcome
        guard case .invalidToken = outcome else {
            Issue.record("expected invalidToken, got \(outcome)")
            return
        }
        #expect(!(await controller.canSave))
    }

    @Test
    func checkAgainstAnUnreachableHostReportsUnreachable() async throws {
        let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        let controller = await RemoteExecutionSettingsController(configuration: configuration)
        await MainActor.run {
            controller.host = "damso-test-host-that-does-not-exist.invalid"
            controller.port = "8787"
            controller.token = "irrelevant"
        }

        await controller.runCheck()
        try await Self.waitUntilNotChecking(controller)

        let outcome = await controller.outcome
        guard case .unreachable = outcome else {
            Issue.record("expected unreachable, got \(outcome)")
            return
        }
        #expect(!(await controller.canSave))
    }

    @MainActor
    private static func waitUntilNotChecking(_ controller: RemoteExecutionSettingsController, timeout: TimeInterval = 20) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if controller.outcome != .checking { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw LiveDamsoServerProcess.StartupFailure(message: "Check did not resolve within \(timeout)s")
    }
}
