import Foundation
@testable import Damso

/// Spawns the real backend HTTP daemon (`python3 -m damso.server.main`, the
/// exact module `LocalServerLifecycle` and `make install-server` both run)
/// against a scratch store, so pairing preflight, token auth, and local
/// daemon lifecycle tests exercise the actual client/server wire behavior
/// instead of a mock - matching this project's existing real-process testing
/// style (`backend/tests/test_server_http.py`, `test_audio_regression.py`).
final class LiveDamsoServerProcess {
    struct Credentials {
        let token: String
    }

    struct StartupFailure: Error {
        let message: String
    }

    let port: Int
    let storeRoot: URL
    let credentials: Credentials?
    private let process: Process

    var processIdentifier: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }

    private init(process: Process, port: Int, storeRoot: URL, credentials: Credentials?) {
        self.process = process
        self.port = port
        self.storeRoot = storeRoot
        self.credentials = credentials
    }

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/DamsoTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    /// `host: "127.0.0.1"` starts the loopback path `LocalServerLifecycle`
    /// uses in local mode (no credentials). Any other host starts the
    /// bearer-token path with a freshly generated, scratch-directory-only
    /// token, mirroring the Python side's `RemoteAuthTests`. Both speak plain
    /// HTTP (ADR 0003).
    static func start(host: String, timeout: TimeInterval = 15) throws -> LiveDamsoServerProcess {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("damso-live-server-\(UUID().uuidString)", isDirectory: true)
        let storeRoot = scratch.appendingPathComponent("store", isDirectory: true)
        try fileManager.createDirectory(at: storeRoot.appendingPathComponent("Plaud/recordings"), withIntermediateDirectories: true)

        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = repositoryRoot().appendingPathComponent("backend").path

        var credentials: Credentials?
        if host != "127.0.0.1" {
            let credentialsDirectory = scratch.appendingPathComponent("creds", isDirectory: true)
            credentials = try generateCredentials(pythonEnvironment: environment, credentialsDirectory: credentialsDirectory)
            environment["DAMSO_SERVER_CREDENTIALS_DIR"] = credentialsDirectory.path
        }

        let port = LocalServerLifecycle.findAvailablePort(preferred: Int.random(in: 20000..<40000))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "damso.server.main", "--store", storeRoot.path, "--host", host, "--port", String(port)]
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()

        let instance = LiveDamsoServerProcess(process: process, port: port, storeRoot: storeRoot, credentials: credentials)
        try instance.waitUntilHealthy(timeout: timeout)
        return instance
    }

    private static func generateCredentials(pythonEnvironment: [String: String], credentialsDirectory: URL) throws -> Credentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "damso.server.credentials", "generate", "--credentials-dir", credentialsDirectory.path]
        process.environment = pythonEnvironment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw StartupFailure(message: "credential generation exited with status \(process.terminationStatus)")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        struct Envelope: Decodable { let token: String }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return Credentials(token: envelope.token)
    }

    private func waitUntilHealthy(timeout: TimeInterval) throws {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/health")!
        let session = URLSession(configuration: .ephemeral)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard process.isRunning else {
                throw StartupFailure(message: "server process exited before becoming healthy")
            }
            if probeOnce(session: session, url: url) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw StartupFailure(message: "server did not become healthy within \(timeout)s")
    }

    private func probeOnce(session: URLSession, url: URL) -> Bool {
        guard let (_, response) = try? blockingDataTask(session: session, request: URLRequest(url: url, timeoutInterval: 1), timeout: 1.5) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func stop() {
        guard process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: storeRoot.deletingLastPathComponent())
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }
    }
}

/// Mirrors `DamsoHTTPClient`'s own hard backstop: a `DispatchSemaphore.wait(timeout:)`
/// that gives up waiting on the calling side, not cooperative `Task` cancellation.
/// This sandbox can leave a stalled connect phase where the
/// `URLSessionTask` completion handler never fires and never responds to
/// cancellation either - `LiveDamsoServerProcess.probeOnce` already needed this
/// same defense, and any test that talks to a real socket directly (rather
/// than through `DamsoHTTPClient`, which already has it) needs it too, or a
/// single stuck request can hang the entire `swift test --parallel` run.
func dataWithHardTimeout(session: URLSession, request: URLRequest, timeout: TimeInterval = 10) async throws -> (Data, URLResponse) {
    // Deliberately a dedicated `Thread`, not `Task.detached`: the latter
    // still runs on Swift Concurrency's cooperative thread pool, which is
    // sized to the core count. Under the full `swift test --parallel` run,
    // dozens of pre-existing tests already block a pool thread on exactly
    // this semaphore pattern via `DamsoHTTPClient.performSynchronously`;
    // adding more `Task.detached`-based blocking waits on top of that
    // reproducibly exhausted the pool and deadlocked (confirmed via `sample`
    // - every thread stuck resuming the same `#expect(throws:)` closure,
    // never progressing). A plain `Thread` can never consume a cooperative
    // pool slot, so it cannot contribute to that starvation.
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
        let thread = Thread {
            do {
                let result = try blockingDataTask(session: session, request: request, timeout: timeout)
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }
}

private func blockingDataTask(session: URLSession, request: URLRequest, timeout: TimeInterval) throws -> (Data, URLResponse) {
    final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<(Data, URLResponse), Error>?
        func set(_ newValue: Result<(Data, URLResponse), Error>) {
            lock.lock()
            if value == nil { value = newValue }
            lock.unlock()
        }
        func get() -> Result<(Data, URLResponse), Error>? {
            lock.lock(); defer { lock.unlock() }; return value
        }
    }
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox()
    let task = session.dataTask(with: request) { data, response, error in
        if let error {
            box.set(.failure(error))
        } else if let data, let response {
            box.set(.success((data, response)))
        } else {
            box.set(.failure(URLError(.unknown)))
        }
        semaphore.signal()
    }
    task.resume()
    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        task.cancel()
        throw URLError(.timedOut)
    }
    switch box.get() {
    case .success(let value): return value
    case .failure(let error): throw error
    case .none: throw URLError(.unknown)
    }
}

func dataWithHardTimeout(session: URLSession, url: URL, timeout: TimeInterval = 10) async throws -> (Data, URLResponse) {
    try await dataWithHardTimeout(session: session, request: URLRequest(url: url, timeoutInterval: timeout), timeout: timeout)
}
