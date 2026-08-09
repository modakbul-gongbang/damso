import Foundation

/// Must track `backend/damso/serve.py`'s `PROTOCOL_VERSION` and
/// `PROTOCOL_VERSION_MISMATCH_CODE` exactly; this is the only contract that
/// keeps a mismatched Mac mini / Mac client pair from silently disagreeing
/// about a store-mutating request's shape.
enum DamsoServeProtocol {
    static let version = 1
    static let versionMismatchErrorCode = -32001
}

/// Where the canonical store lives for this app instance: on this Mac, or on
/// a Mac mini reached over SSH. Every helper-process spawn point reads this
/// once instead of each independently deciding how to run its argv.
enum CommandExecutionMode: Equatable {
    case local
    case remote(host: String, interpreterPath: String)
}

/// Owns the local/remote execution decision and the remote connection facts
/// a client Mac needs to reach the Mac mini's canonical store: the SSH host
/// alias, the mini's absolute Python interpreter path (never bare `python3` -
/// a non-interactive SSH shell's PATH is only `/usr/bin:/bin:/usr/sbin:/sbin`
/// and would silently resolve the system Python instead), and the mini's
/// absolute store root path.
/// `@unchecked`: `UserDefaults` is thread-safe, and `InMemoryConfigurationPreferences`
/// (test-only) is a simple dictionary wrapper never shared across threads
/// concurrently. Needed so `CommandLauncher`/`RemoteAudioFetcher` can cross
/// into a `Task.detached` from `@MainActor` code without a data-race error.
final class RemoteExecutionConfiguration: @unchecked Sendable {
    static let hostKey = "damso.remoteExecution.host"
    static let interpreterPathKey = "damso.remoteExecution.interpreterPath"
    static let storeRootPathKey = "damso.remoteExecution.storeRootPath"

    private let preferences: ConfigurationPreferences

    init(preferences: ConfigurationPreferences = UserDefaults.standard) {
        self.preferences = preferences
    }

    var mode: CommandExecutionMode {
        guard let host = preferences.string(forKey: Self.hostKey), !host.isEmpty,
              let interpreterPath = preferences.string(forKey: Self.interpreterPathKey), !interpreterPath.isEmpty else {
            return .local
        }
        return .remote(host: host, interpreterPath: interpreterPath)
    }

    /// The mini's absolute canonical store root, set only in remote mode.
    /// Callers building a request payload (recording_directory,
    /// peoples_directory, --store) must resolve through this, never through
    /// a locally-selected `StorageRootConfiguration` path, or a remote
    /// request would carry a path that only exists on the client.
    var remoteStoreRootPath: String? {
        guard let path = preferences.string(forKey: Self.storeRootPathKey), !path.isEmpty else {
            return nil
        }
        return path
    }

    func configureRemote(host: String, interpreterPath: String, storeRootPath: String) {
        preferences.setString(host, forKey: Self.hostKey)
        preferences.setString(interpreterPath, forKey: Self.interpreterPathKey)
        preferences.setString(storeRootPath, forKey: Self.storeRootPathKey)
    }

    func clearRemote() {
        preferences.setString(nil, forKey: Self.hostKey)
        preferences.setString(nil, forKey: Self.interpreterPathKey)
        preferences.setString(nil, forKey: Self.storeRootPathKey)
    }
}

enum CommandLauncherError: Error, Equatable {
    case launchFailed
    case oversizedResponse
}

struct CommandLauncherOutput {
    let data: Data
    let terminationStatus: Int32
}

/// The one Process()-spawning implementation shared by every `Local*Command`
/// runner. It only decides *where* the fixed argv runs (this Mac, or the
/// configured mini over SSH) and moves bytes; request encoding and response
/// decoding stay with each call site so their existing error handling is
/// unchanged.
struct CommandLauncher {
    let configuration: RemoteExecutionConfiguration

    init(configuration: RemoteExecutionConfiguration = RemoteExecutionConfiguration()) {
        self.configuration = configuration
    }

    /// A non-interactive SSH shell's PATH is only `/usr/bin:/bin:/usr/sbin:/sbin`
    /// (verified against the mini, D-B1): the Python interpreter itself is
    /// always passed as an absolute path regardless, but `damso.processing`
    /// also shells out to bare `ffmpeg`, which lives under `/opt/homebrew/bin`
    /// and would otherwise fail to resolve mid-pipeline. This is prepended to
    /// every remote command so tools the mini's own Python code invokes by
    /// bare name keep working exactly as they do in an interactive shell.
    ///
    /// `$HOME/.local/bin` is where the Claude Code CLI installs itself, and
    /// `agent_boundary` finds it with a bare `shutil.which("claude")`. Leaving
    /// it out made every summary on a two-machine setup fail as
    /// `agent_cli_missing` while the CLI sat installed and signed in on the
    /// server. `ProcessRuntime.environment()` already lists it for local
    /// subprocesses; this keeps the remote side saying the same thing.
    /// Unquoted on purpose - this element is handed to the remote shell as
    /// shell text (unlike the command arguments, which are quoted), so `$HOME`
    /// expands to the *server's* home, which is routinely not this Mac's.
    static let remotePathPrefix = "PATH=/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    /// Builds the argv for one Python module invocation, local or ssh-wrapped
    /// depending on `configuration.mode`. `pythonExecutable` is used only in
    /// local mode; the remote interpreter is always the configured absolute
    /// path, never a bare name, per the non-interactive PATH pitfall above.
    ///
    /// SSH does not preserve each remote argument as a separate field: it
    /// joins every argument after the host with a single space and hands that
    /// one string to the remote shell to re-tokenize. A store path containing
    /// spaces (the mini's real store root is
    /// `~/Library/Application Support/Damso`) would silently split into
    /// multiple arguments without per-argument shell quoting here - verified
    /// against the mini: `ssh mini /bin/echo one "two three" four` prints
    /// `one two three four`, not `one`, `two three`, `four`.
    func argv(module: String, moduleArguments: [String] = [], pythonExecutable: String = "python3") -> [String] {
        switch configuration.mode {
        case .local:
            return [pythonExecutable, "-m", module] + moduleArguments
        case .remote(let host, let interpreterPath):
            let remoteCommand = [interpreterPath, "-m", module] + moduleArguments
            return ["ssh"] + Self.sshOptions + [host, Self.remotePathPrefix] + remoteCommand.map(Self.shellQuote)
        }
    }

    /// Without `ConnectTimeout`, a dropped mini leaves `ssh` hanging on the
    /// OS's own TCP retry (tens of seconds to minutes) instead of failing
    /// fast enough for R9(c)'s "disable at attempt time" promise to mean
    /// anything. `BatchMode=yes` turns a would-be interactive password/host-key
    /// prompt into an immediate failure instead of a hang waiting on stdin
    /// that this non-interactive process never supplies.
    static let sshOptions = ["-o", "ConnectTimeout=5", "-o", "BatchMode=yes"]

    /// The same fast-fail options as `sshOptions`, shaped for rsync's
    /// `--rsh=` (rsync launches its own ssh transport for a `host:path`
    /// argument, so it never picks up `sshOptions` above on its own).
    /// Used by every rsync-based remote path: cache sync, outbox handoff,
    /// and on-demand audio fetch.
    static let rsyncRemoteShellArgument = "--rsh=ssh -o ConnectTimeout=5 -o BatchMode=yes"

    /// POSIX single-quote escaping: wraps in single quotes and turns any
    /// embedded single quote into `'\''` (close quote, escaped literal quote,
    /// reopen quote) so the remote shell reconstructs exactly one argument.
    static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    func run(
        argv: [String],
        input: Data? = nil,
        environment: [String: String] = ProcessRuntime.environment(),
        maximumResponseBytes: Int
    ) throws -> CommandLauncherOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.environment = environment

        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = Pipe()

        var standardInput: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            standardInput = pipe
        }

        do {
            try process.run()
        } catch {
            throw CommandLauncherError.launchFailed
        }

        if let input, let standardInput {
            standardInput.fileHandleForWriting.write(input)
            try? standardInput.fileHandleForWriting.close()
        }

        // Read to EOF before waiting: a child that writes more than one pipe
        // buffer (64KB on macOS) blocks on write() once the buffer fills, so
        // calling waitUntilExit() first would deadlock against a child that
        // is itself blocked waiting for us to drain its stdout.
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard output.count <= maximumResponseBytes else {
            throw CommandLauncherError.oversizedResponse
        }
        return CommandLauncherOutput(data: output, terminationStatus: process.terminationStatus)
    }
}

enum DamsoServeError: Error, Equatable {
    case requestEncoding
    case launchFailed
    case oversizedResponse
    case remoteMisconfigured
    /// `ssh`/the remote Python process exited non-zero before producing a
    /// decodable response - a dropped connection, refused connection, or a
    /// crash on the mini's side, not a client-side bug. Previously
    /// indistinguishable from `.invalidResponse` because nothing checked
    /// `CommandLauncherOutput.terminationStatus` here; see
    /// `RemoteConnectivityTracker`.
    case transportFailed(exitCode: Int32)
    /// `damso.serve` rejected the request's protocol_version specifically -
    /// surfaced as one message: update Damso on the Mac mini.
    case remoteUpdateRequired
    /// Any other JSON-RPC-shaped protocol-level rejection (parse error,
    /// unknown operation) - a client bug, not a version skew.
    case protocolError(code: Int, message: String)
    /// A known operation that failed inside its own Python logic; mirrors
    /// `damso.processing`'s own local error envelope exactly.
    case backend(code: String, nextAction: String)
    case invalidResponse
}

/// The one client for talking to `backend/damso/serve.py`: injects
/// `protocol_version`, ssh-wraps via `CommandLauncher`, and unwraps the two
/// response shapes `serve.py` can return - see its module docstring. Both the
/// original 7 `processing.py`-delegated operations (`LocalProcessingCommand`)
/// and the 9 record/people operations (`RemoteMeetingStore`) share this, so
/// the wire protocol is defined in exactly one place.
struct DamsoServeClient {
    let launcher: CommandLauncher
    /// Defaults to the process-wide singleton; tests inject a fresh instance
    /// so exercising a real connectivity outcome here never leaks into
    /// another test's `connectionStatus` expectations.
    let tracker: RemoteConnectivityTracker
    private static let maximumResponseBytes = 64 * 1_024

    init(launcher: CommandLauncher, tracker: RemoteConnectivityTracker = .shared) {
        self.launcher = launcher
        self.tracker = tracker
    }

    /// Encodes `request`, injects `protocol_version`, runs it against
    /// `damso.serve` on the configured mini, and returns the raw response
    /// bytes after rejecting a protocol-level error. Callers decode the
    /// remaining ok/error envelope themselves via `DamsoServeClient.decode`,
    /// since its success shape differs per operation.
    func send(_ request: some Encodable) throws -> Data {
        guard let remoteStoreRoot = launcher.configuration.remoteStoreRootPath else {
            throw DamsoServeError.remoteMisconfigured
        }
        let input: Data
        do {
            let encoder = JSONEncoder()
            // update-record's payload embeds a full MeetingRecord, whose Date
            // fields (createdAt, ...) must round-trip through the same ISO
            // 8601 shape the canonical meeting.json files already use.
            DateCoding.configure(encoder)
            input = try encoder.encode(request)
        } catch {
            throw DamsoServeError.requestEncoding
        }
        let versioned = try Self.injectProtocolVersion(into: input)
        let argv = launcher.argv(module: "damso.serve", moduleArguments: ["--store", remoteStoreRoot])
        do {
            let output = try launcher.run(argv: argv, input: versioned, maximumResponseBytes: Self.maximumResponseBytes)
            let data = try Self.processOutput(output)
            tracker.noteSuccess()
            return data
        } catch let error as DamsoServeError {
            tracker.noteFailure(error)
            throw error
        } catch CommandLauncherError.oversizedResponse {
            tracker.noteFailure(.oversizedResponse)
            throw DamsoServeError.oversizedResponse
        } catch {
            tracker.noteFailure(.launchFailed)
            throw DamsoServeError.launchFailed
        }
    }

    /// Split out from `send` so a synthetic `CommandLauncherOutput` (no real
    /// process spawn) can exercise the exit-status/protocol-error checks
    /// directly, the same way `LocalProcessingProcessRunner.decode` is tested.
    static func processOutput(_ output: CommandLauncherOutput) throws -> Data {
        // Checked before decoding anything: a dropped/refused ssh connection
        // exits non-zero with empty or partial stdout, which would otherwise
        // fall through to a misleading `.invalidResponse` ("the mini sent
        // garbage") instead of the true "the mini was unreachable".
        guard output.terminationStatus == 0 else {
            throw DamsoServeError.transportFailed(exitCode: output.terminationStatus)
        }
        try Self.rejectProtocolError(output.data)
        return output.data
    }

    static func injectProtocolVersion(into data: Data) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DamsoServeError.requestEncoding
        }
        object["protocol_version"] = DamsoServeProtocol.version
        do {
            return try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw DamsoServeError.requestEncoding
        }
    }

    private struct ProtocolErrorEnvelope: Decodable {
        struct Details: Decodable {
            let code: Int
            let message: String
        }

        let jsonrpc: String
        let error: Details
    }

    /// `damso.serve`'s JSON-RPC-shaped protocol errors (bad protocol_version,
    /// unknown operation, parse error) only ever appear at this envelope
    /// shape; a known operation's own success or failure never does (mirrors
    /// `mcp.py`'s envelope, see `serve.py`).
    static func rejectProtocolError(_ data: Data) throws {
        guard let envelope = try? JSONDecoder().decode(ProtocolErrorEnvelope.self, from: data) else {
            return
        }
        if envelope.error.code == DamsoServeProtocol.versionMismatchErrorCode {
            throw DamsoServeError.remoteUpdateRequired
        }
        throw DamsoServeError.protocolError(code: envelope.error.code, message: envelope.error.message)
    }

    private struct BackendErrorEnvelope: Decodable {
        struct Details: Decodable {
            let code: String
            let nextAction: String

            enum CodingKeys: String, CodingKey {
                case code
                case nextAction = "next_action"
            }
        }

        let ok: Bool
        let error: Details
    }

    /// Decodes a response already passed through `rejectProtocolError`: an
    /// operation-level failure decodes as `BackendErrorEnvelope` first (its
    /// two required, non-optional fields only match that specific shape),
    /// otherwise as the caller's own success type.
    static func decode<Response: Decodable>(_ data: Data, as type: Response.Type) throws -> Response {
        if let envelope = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data), !envelope.ok {
            throw DamsoServeError.backend(code: envelope.error.code, nextAction: envelope.error.nextAction)
        }
        let decoder = JSONDecoder()
        DateCoding.configure(decoder)
        guard let result = try? decoder.decode(Response.self, from: data) else {
            throw DamsoServeError.invalidResponse
        }
        return result
    }
}
