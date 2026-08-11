import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// D-10/T7: local mode's daemon lifecycle is the app's job, not launchd's -
/// "install one app" must stay the whole story for a single-machine setup.
/// Spawns `damso-server` as a child process bound to loopback, health-checks
/// it, respawns it on an unexpected exit, and terminates it (via
/// `ProcessingOrphanSweeper`'s reused reap mechanism) when the app quits.
/// Never used in remote mode, where the operator's own `make install-server`
/// + launchd owns the daemon's lifecycle entirely.
@MainActor
final class LocalServerLifecycle: ObservableObject {
    enum State: Equatable {
        case notInstalled
        case starting
        case ready(port: Int)
        case crashed
    }

    @Published private(set) var state: State = .starting

    private let configuration: ServerConnectionConfiguration
    private let storeRootPath: () -> String
    /// `private(set)`, not `private`, so tests can reach the real spawned
    /// PID and simulate an actual crash (`kill(pid, SIGKILL)`) rather than
    /// only exercising `stop()`'s own intentional-shutdown path.
    private(set) var process: Process?
    private var healthCheckTask: Task<Void, Never>?
    private var respawnAttempts = 0
    private static let maximumRespawnAttempts = 3
    /// Set for the duration of an intentional `stop()` so the termination
    /// handler it triggers (SIGTERM still exits the process asynchronously,
    /// racing `stop()`'s own `self.process = nil`) treats the exit as
    /// expected rather than a crash to respawn from.
    private var isStopping = false

    init(configuration: ServerConnectionConfiguration = ServerConnectionConfiguration(), storeRootPath: @escaping () -> String) {
        self.configuration = configuration
        self.storeRootPath = storeRootPath
    }

    /// Only meaningful in local mode; a caller in remote mode should never
    /// invoke this (the app never spawns anything against a remote daemon).
    func start() {
        guard case .local = configuration.mode else { return }
        Task { await spawn() }
    }

    func stop() {
        healthCheckTask?.cancel()
        isStopping = true
        guard let process, process.isRunning else { return }
        process.terminate()
        process.waitUntilExit()
        self.process = nil
    }

    private func spawn() async {
        isStopping = false
        state = .starting
        guard let interpreter = Self.resolveServerExecutable() else {
            state = .notInstalled
            return
        }
        let port = Self.findAvailablePort(preferred: ServerConnectionConfiguration.defaultPort)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [interpreter, "-m", "damso.server.main", "--store", storeRootPath(), "--host", "127.0.0.1", "--port", String(port)]
        process.environment = ProcessRuntime.environment()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleUnexpectedExit()
            }
        }
        do {
            try process.run()
        } catch {
            state = .notInstalled
            return
        }
        self.process = process
        configuration.recordLocalPort(port)
        await waitForHealth(port: port)
    }

    private func waitForHealth(port: Int) async {
        let url = URL(string: "http://127.0.0.1:\(port)/v1/health")!
        for _ in 0..<50 {
            if let (_, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 1)),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                respawnAttempts = 0
                state = .ready(port: port)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        state = .crashed
    }

    private func handleUnexpectedExit() {
        process = nil
        guard !isStopping else { return }
        guard state != .notInstalled else { return }
        respawnAttempts += 1
        guard respawnAttempts <= Self.maximumRespawnAttempts else {
            state = .crashed
            return
        }
        Task { await spawn() }
    }

    /// Finds a free loopback port, preferring the fixed default (D-19) so a
    /// fresh machine with nothing else listening always uses it, and falling
    /// back to any free ephemeral port on conflict (D-22) - silently; the
    /// client is the only thing that ever needs to know the chosen port
    /// (`ServerConnectionConfiguration.recordLocalPort`).
    /// `nonisolated`: pure socket-syscall computation, no access to any
    /// instance or class state - callers (including tests) can use it
    /// without hopping onto the main actor.
    nonisolated static func findAvailablePort(preferred: Int) -> Int {
        if isPortFree(preferred) { return preferred }
        return freeEphemeralPort() ?? preferred
    }

    private nonisolated static func isPortFree(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    private nonisolated static func freeEphemeralPort() -> Int? {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &assigned) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                getsockname(descriptor, rebound, &length)
            }
        }
        guard read == 0 else { return nil }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    /// The `damso-server` package is installed by `make install-server` into
    /// whichever Python interpreter that ran (system, Homebrew, or a
    /// virtualenv); there is no fixed absolute path to assume the way the
    /// SSH-era remote interpreter had to be. `python3 -m damso.server.main`
    /// resolves correctly whenever the package is on that interpreter's
    /// `sys.path`, so this only needs to confirm the module actually imports
    /// before returning `python3` as the executable to use.
    private static func resolveServerExecutable() -> String? {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        probe.arguments = ["python3", "-c", "import damso.server.main"]
        probe.environment = ProcessRuntime.environment()
        probe.standardOutput = Pipe()
        probe.standardError = Pipe()
        do {
            try probe.run()
        } catch {
            return nil
        }
        probe.waitUntilExit()
        return probe.terminationStatus == 0 ? "python3" : nil
    }
}
