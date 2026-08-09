import Foundation

/// Which half of the two-machine split (R13) this running process is. A
/// single binary runs on both the MacBook and the mini; nothing else in the
/// process tells the two apart, so this is the one place that decides.
enum InstanceRole: Equatable {
    /// Pre-split (or a still-solo user): does everything on one machine.
    case combined
    /// The MacBook side of a split: detects and records, but never decides
    /// when to run heavy processing - the mini's own `.combined`/`.server`
    /// instance orchestrates that against the canonical store it owns.
    case client
    /// The mini side of a split: owns the canonical store and processing,
    /// never watches the mic or browser tabs for a meeting.
    case server

    /// R13's explicit-setting escape hatch: a launch argument rather than an
    /// environment variable or UserDefaults preference. The mini install has
    /// no Settings UI to set a preference from, and (D-B3) a GUI app launched
    /// remotely only reliably receives argv - `open -a Damso.app --args
    /// --server-role` - not custom environment variables, since `open` hands
    /// the request to LaunchServices rather than forking with an inherited
    /// environment. The LaunchAgent's own `ProgramArguments` carries the same
    /// flag directly, so a manual bootstrap launch and every later
    /// LaunchAgent-driven relaunch resolve to the same role.
    static let serverRoleArgument = "--server-role"

    /// Takes the already-resolved store's type rather than reading
    /// `RemoteExecutionConfiguration` itself, so this stays tied to what the
    /// instance actually constructed (test fixtures inject a local store
    /// explicitly) instead of ambient state on whatever machine runs it.
    /// R13: a remote store is unambiguous (only a MacBook talking to a mini
    /// ever has one), so it always wins over the explicit setting - a
    /// `client` can't also be told to act as `server`.
    static func current(isRemoteStore: Bool, arguments: [String] = CommandLine.arguments) -> InstanceRole {
        if isRemoteStore {
            return .client
        }
        if arguments.contains(serverRoleArgument) {
            return .server
        }
        return .combined
    }

    /// Meeting detection (mic/tab watching) and recording capture.
    var detectsAndRecords: Bool { self != .server }
    /// Deciding when to resume/queue heavy processing for a record - not the
    /// same as running it (a `client` still ssh-runs `damso.processing`
    /// itself, per-call, when the mini's own sweep is what queued it).
    var orchestratesProcessing: Bool { self != .client }

    /// The absolute Python interpreter this machine's own local processing
    /// subprocesses should use, when a bare `python3` is not reliably
    /// resolvable. R5 already requires an absolute interpreter path for the
    /// SSH-remote case (a non-interactive shell's PATH is too narrow, D-B1);
    /// this closes the identical gap for a server-role instance's own
    /// LOCAL processing (its sweep-triggered `damso.processing` etc. spawn a
    /// bare "python3" by default, same as a single-machine install). A
    /// `brew install python@<version>` formula deliberately does not symlink
    /// a generic `python3` - only the versioned binary - so PATH falls
    /// through to the system Python (verified against the mini: bare
    /// `python3` resolves to `/usr/bin/python3`, 3.9.6, missing every
    /// local-processing dependency, while `damso.serve`'s SSH-remote path
    /// already worked because it always used the mini's absolute
    /// `/opt/homebrew/bin/python3.12`). A launch argument, not an env var or
    /// preference, for the same reason as `serverRoleArgument` - the mini
    /// install has no Settings UI, and only argv survives both a manual
    /// `open --args` bootstrap and every later LaunchAgent relaunch reliably.
    static let localPythonArgumentPrefix = "--local-python="

    static func localPythonExecutable(arguments: [String] = CommandLine.arguments) -> String? {
        for argument in arguments where argument.hasPrefix(localPythonArgumentPrefix) {
            return String(argument.dropFirst(localPythonArgumentPrefix.count))
        }
        return nil
    }
}
