import Foundation
import Testing
@testable import Damso

#if canImport(Darwin)
import Darwin
#endif

/// T7/AC1: local mode's daemon lifecycle (spawn on loopback, reselect on a
/// port conflict, respawn after a crash) is the app's own job, not
/// launchd's. These tests spawn the real `damso.server.main` process (the
/// same one production code spawns) rather than a fake, because a lifecycle
/// bug only shows up against a real child process's real exit codes and
/// real sockets. Part of `LiveServerIntegrationTests` (declared in
/// `LiveServerIntegrationTests.swift`) - see that file's header for why this is an
/// `extension` rather than its own `@Suite`.
extension LiveServerIntegrationTests {
    @Test
    func findAvailablePortReturnsThePreferredPortWhenItIsFree() {
        let preferred = Int.random(in: 30000..<31000)

        let port = LocalServerLifecycle.findAvailablePort(preferred: preferred)

        #expect(port == preferred)
    }

    @Test
    func findAvailablePortFallsBackWhenThePreferredPortIsAlreadyBound() {
        let preferred = Int.random(in: 31000..<32000)
        let holder = socket(AF_INET, SOCK_STREAM, 0)
        #expect(holder >= 0)
        defer { close(holder) }
        var reuse: Int32 = 1
        setsockopt(holder, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(preferred).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(holder, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bound == 0)
        listen(holder, 1)

        let port = LocalServerLifecycle.findAvailablePort(preferred: preferred)

        #expect(port != preferred)
        #expect(port > 0)
    }

    @Test
    func spawnBecomesReadyOverLoopbackAndStopStopsItCleanly() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Plaud/recordings"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        let lifecycle = await LocalServerLifecycle(configuration: configuration, storeRootPath: { scratch.path })

        await lifecycle.start()
        let readyPort = try await Self.waitForReady(lifecycle, timeout: 20)

        let health = try? await dataWithHardTimeout(session: URLSession(configuration: .ephemeral), url: URL(string: "http://127.0.0.1:\(readyPort)/v1/health")!)
        let httpResponse = health?.1 as? HTTPURLResponse
        #expect(httpResponse?.statusCode == 200)

        await lifecycle.stop()
        // Give the terminated process a moment to actually release the
        // socket before asserting it is gone; also proves stop() does not
        // trigger the crash-respawn path (a respawn would still answer here).
        try await Task.sleep(for: .seconds(2))
        let afterStop = try? await dataWithHardTimeout(session: URLSession(configuration: .ephemeral), url: URL(string: "http://127.0.0.1:\(readyPort)/v1/health")!)
        #expect(afterStop == nil)
    }

    @Test
    func killingTheChildProcessTriggersAnAutomaticRespawn() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Plaud/recordings"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        let lifecycle = await LocalServerLifecycle(configuration: configuration, storeRootPath: { scratch.path })

        await lifecycle.start()
        _ = try await Self.waitForReady(lifecycle, timeout: 20)
        let firstProcess = try #require(await lifecycle.process)
        let firstPID = firstProcess.processIdentifier

        kill(firstPID, SIGKILL)

        // Wait for a genuinely new `Process` object first, identified by
        // reference rather than PID: this sandbox recycles PIDs fast enough
        // that a respawned process can legitimately reuse the exact same
        // PID, which would make a PID-equality check pass without ever
        // observing a real respawn. Reading `.state` right after `kill()`
        // has the same problem for a different reason - the termination
        // handler dispatches asynchronously, so it can still observe the
        // pre-crash `.ready` value.
        let secondProcess = try await Self.waitForADifferentProcessObject(lifecycle, than: firstProcess, timeout: 20)
        #expect(secondProcess !== firstProcess)

        // Now that a new process genuinely exists, wait for it to answer
        // its own health check - proving handleUnexpectedExit's respawn
        // actually completes, not just that a process object was created.
        let respawnedPort = try await Self.waitForReady(lifecycle, timeout: 20)

        let health = try? await dataWithHardTimeout(session: URLSession(configuration: .ephemeral), url: URL(string: "http://127.0.0.1:\(respawnedPort)/v1/health")!)
        let httpResponse = health?.1 as? HTTPURLResponse
        #expect(httpResponse?.statusCode == 200)

        await lifecycle.stop()
    }

    @MainActor
    private static func waitForReady(_ lifecycle: LocalServerLifecycle, timeout: TimeInterval) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch lifecycle.state {
            case .ready(let port):
                return port
            case .crashed, .notInstalled:
                Issue.record("lifecycle reached \(lifecycle.state) while waiting for .ready")
                throw LiveDamsoServerProcess.StartupFailure(message: "lifecycle failed: \(lifecycle.state)")
            case .starting:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        throw LiveDamsoServerProcess.StartupFailure(message: "lifecycle did not become ready within \(timeout)s")
    }

    @MainActor
    private static func waitForADifferentProcessObject(_ lifecycle: LocalServerLifecycle, than old: Process, timeout: TimeInterval) async throws -> Process {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = lifecycle.process, current !== old {
                return current
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        throw LiveDamsoServerProcess.StartupFailure(message: "no new child process object observed within \(timeout)s")
    }
}
