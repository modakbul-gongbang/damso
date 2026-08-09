import Foundation

/// Where Damso puts its own files on a provisioned server Mac. Fixed rather
/// than configurable: the whole point of automated provisioning is that the
/// client already knows every path without asking, so a user only ever has to
/// supply the one fact the client cannot derive - the SSH host. The Advanced
/// fields in Settings still override the interpreter and store root for an
/// installation that was set up by hand before this flow existed.
enum RemoteServerLayout {
    static let launchAgentLabel = "com.yansfil.damso.server"
    static let launchAgentFileName = launchAgentLabel + ".plist"

    /// Everything below lives under the server's own Application Support
    /// directory, beside the canonical store, so uninstalling is one delete.
    static func supportRoot(home: String) -> String {
        home + "/Library/Application Support/Damso"
    }

    /// The Python helper package's source, rsynced from this client's app
    /// bundle. Kept on the server (rather than installed and deleted) so a
    /// later re-provision is a diff, not a full re-download.
    static func serverSourceRoot(home: String) -> String {
        supportRoot(home: home) + "/server-src"
    }

    /// Homebrew's Python is PEP 668 externally-managed, so `pip install` into
    /// it fails outright without `--break-system-packages` (verified against
    /// the mini: its `EXTERNALLY-MANAGED` marker is present). Provisioning
    /// therefore builds its own virtualenv instead of arguing with the
    /// system, which also keeps Damso's pinned mlx-whisper/sherpa-onnx from
    /// colliding with anything else the owner installs later.
    static func virtualenvRoot(home: String) -> String {
        supportRoot(home: home) + "/server-venv"
    }

    /// The interpreter every configured path uses afterwards: the client's
    /// saved `interpreterPath`, the LaunchAgent's `--local-python=`, and
    /// `scripts/mcp-remote.sh` all resolve to this one absolute binary.
    static func virtualenvPython(home: String) -> String {
        virtualenvRoot(home: home) + "/bin/python3"
    }

    static func modelRoot(home: String) -> String {
        supportRoot(home: home) + "/Models"
    }

    static func defaultStoreRoot(home: String) -> String {
        supportRoot(home: home)
    }

    static func appBundle(home: String) -> String {
        home + "/Applications/Damso.app"
    }

    static func appExecutable(home: String) -> String {
        appBundle(home: home) + "/Contents/MacOS/Damso"
    }

    static func launchAgent(home: String) -> String {
        home + "/Library/LaunchAgents/" + launchAgentFileName
    }

    static func logDirectory(home: String) -> String {
        home + "/Library/Logs/Damso"
    }
}

/// One line of the setup checklist. Ordered by dependency: a later step's
/// probe is only meaningful once every earlier one is satisfied, which is why
/// `RemoteSetupService.preflight` stops at the first blocking failure instead
/// of reporting a cascade of misleading "missing" rows.
enum RemoteSetupStep: String, CaseIterable, Identifiable, Sendable {
    case connection
    case basePython
    case ffmpeg
    case store
    case environment
    case models
    case app
    case launchAgent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: Loc.tr("SSH connection")
        case .basePython: Loc.tr("Python 3.11 or newer")
        case .ffmpeg: Loc.tr("ffmpeg")
        case .store: Loc.tr("Canonical store")
        case .environment: Loc.tr("Processing environment")
        case .models: Loc.tr("Local models")
        case .app: Loc.tr("Damso app")
        case .launchAgent: Loc.tr("Background service")
        }
    }

    /// Whether "Set up this Mac" can fix this step by itself. The three that
    /// cannot are deliberate: SSH keys and Homebrew packages are the owner's
    /// own machine setup, and copying the canonical store is a multi-gigabyte
    /// move of real meeting data whose ordering matters (the store must land
    /// before Damso ever launches there, or an empty default store is created
    /// and collides), so it stays an explicit, documented manual step.
    var isProvisionable: Bool {
        switch self {
        case .connection, .basePython, .ffmpeg, .store: false
        case .environment, .models, .app, .launchAgent: true
        }
    }

    /// What the owner has to do themselves when a non-provisionable step is
    /// missing. Empty for the provisionable ones - the button handles those.
    var manualHint: String {
        switch self {
        case .connection:
            Loc.tr("Add this Mac's SSH key to the server and confirm `ssh <host>` works from Terminal without a password prompt.")
        case .basePython:
            Loc.tr("Install Python 3.11 or newer on the server, for example with `brew install python@3.12`.")
        case .ffmpeg:
            Loc.tr("Install ffmpeg on the server with `brew install ffmpeg`.")
        case .store:
            Loc.tr("Copy your meeting store to the server before setup, and never launch Damso there first. See the two-machine section of INSTALL.md.")
        case .environment, .models, .app, .launchAgent:
            ""
        }
    }
}

enum RemoteSetupStatus: Equatable, Sendable {
    case unknown
    case checking
    case working(String)
    case satisfied(String)
    case missing(String)
    case failed(String)

    var isSatisfied: Bool {
        if case .satisfied = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .checking, .working: true
        default: false
        }
    }

    var detail: String {
        switch self {
        case .unknown: ""
        case .checking: Loc.tr("Checking…")
        case .working(let detail), .satisfied(let detail), .missing(let detail), .failed(let detail): detail
        }
    }
}

/// What preflight learned about the server, used both to fill the Advanced
/// fields and to build every later provisioning command.
struct RemoteServerFacts: Equatable, Sendable {
    /// The server's own `$HOME`, read over SSH rather than guessed - the
    /// account name there is frequently not the one on this Mac.
    var home: String
    var architecture: String
    /// An existing Python >= 3.11 on the server, used only to build the
    /// virtualenv. Never the interpreter Damso itself runs afterwards.
    var basePython: String?

    var isAppleSilicon: Bool { architecture == "arm64" }
}

/// The connection probe's two outcomes. An enum rather than `Result` because
/// a failed probe carries a display status, not a thrown error - nothing here
/// is recoverable by a `catch`, it is all shown to the owner as a checklist row.
enum RemoteConnectionOutcome: Equatable, Sendable {
    case connected(RemoteServerFacts)
    case unavailable(RemoteSetupStatus)
}

/// The one process-spawning seam, injected so every script/argv decision in
/// this file is testable without touching a real machine.
struct RemoteSetupRunner: Sendable {
    var execute: @Sendable (_ argv: [String], _ input: Data?) -> CommandLauncherOutput?

    /// Reuses `CommandLauncher.run`, which already reads stdout to EOF before
    /// `waitUntilExit()` - provisioning output (pip, rsync) easily exceeds one
    /// 64KB pipe buffer, exactly the deadlock that runner was fixed for.
    static let live = RemoteSetupRunner { argv, input in
        try? CommandLauncher().run(argv: argv, input: input, maximumResponseBytes: 4 * 1_024 * 1_024)
    }
}

/// Builds every remote command this flow runs. Split out as pure functions so
/// the escaping rules - which are where all the real bugs live - are asserted
/// directly in tests instead of only end to end.
enum RemoteSetupCommands {
    /// SSH hands every argument after the host to the remote *login* shell as
    /// one re-tokenized string, so a script is passed as a single argument and
    /// any value interpolated into it must already be shell-quoted.
    static func ssh(host: String, script: String) -> [String] {
        ["ssh"] + CommandLauncher.sshOptions + [host, script]
    }

    /// macOS's bundled openrsync fails with "server receiver mode requires two
    /// argument" when a remote path contains an unescaped space, and the store
    /// root always does (`Library/Application Support/Damso`). Only the remote
    /// side needs this; the local path is passed as its own argv element and
    /// never reaches a shell.
    static func rsyncRemotePath(host: String, path: String) -> String {
        host + ":" + path.replacingOccurrences(of: " ", with: "\\ ")
    }

    static func rsync(localDirectory: String, host: String, remoteDirectory: String, delete: Bool) -> [String] {
        var argv = ["rsync", "-a", CommandLauncher.rsyncRemoteShellArgument]
        if delete {
            argv.append("--delete")
        }
        // Trailing slashes on both sides: copy the directory's *contents* into
        // the destination directory rather than nesting it one level deeper.
        argv.append(localDirectory + "/")
        argv.append(rsyncRemotePath(host: host, path: remoteDirectory) + "/")
        return argv
    }

    /// Reads the two facts the client cannot derive. Also the reachability
    /// probe: an unreachable host fails here with a non-zero ssh exit rather
    /// than an empty-but-successful response.
    static let connectionScript = """
    uname -m
    printf '%s\\n' "$HOME"
    """

    /// Deliberately glob-free. A remote login shell on macOS is zsh, whose
    /// default `nomatch` aborts the *entire* command line when any glob
    /// matches nothing - so `ls /opt/homebrew/bin/python3.*` silently takes
    /// the rest of the script down with it when only one prefix is missing
    /// (observed while probing the mini by hand). An explicit candidate list
    /// with `[ -x ]` has no such failure mode and is deterministic besides.
    static let basePythonCandidates = [
        "/opt/homebrew/bin/python3.13",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3.11",
        "/usr/local/bin/python3.13",
        "/usr/local/bin/python3.12",
        "/usr/local/bin/python3.11",
        "/usr/bin/python3",
    ]

    static var basePythonScript: String {
        let candidates = basePythonCandidates.map(CommandLauncher.shellQuote).joined(separator: " ")
        return """
        for candidate in \(candidates); do
          if [ -x "$candidate" ] && "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
            printf '%s\\n' "$candidate"
            exit 0
          fi
        done
        exit 1
        """
    }

    static let ffmpegCandidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]

    static var ffmpegScript: String {
        let candidates = ffmpegCandidates.map(CommandLauncher.shellQuote).joined(separator: " ")
        return """
        for candidate in \(candidates); do
          if [ -x "$candidate" ]; then
            printf '%s\\n' "$candidate"
            exit 0
          fi
        done
        exit 1
        """
    }

    /// A store root only counts as a real canonical store when it already has
    /// the record tree in it - an empty `Damso` directory is exactly what a
    /// prematurely-launched server app leaves behind, and treating that as
    /// "present" would hide the one ordering mistake this check exists for.
    static func storeScript(storeRoot: String) -> String {
        let quoted = CommandLauncher.shellQuote(storeRoot + "/Plaud/recordings")
        return "test -d \(quoted) && printf 'present\\n'"
    }

    static func environmentScript(interpreterPath: String) -> String {
        let quoted = CommandLauncher.shellQuote(interpreterPath)
        return "test -x \(quoted) && \(quoted) -c 'import damso, mlx_whisper, sherpa_onnx; print(\"ready\")'"
    }

    static func modelsScript(interpreterPath: String, modelRoot: String) -> String {
        let interpreter = CommandLauncher.shellQuote(interpreterPath)
        let root = CommandLauncher.shellQuote(modelRoot)
        return "\(CommandLauncher.remotePathPrefix) \(interpreter) -m damso.model_setup --status --model-root \(root)"
    }

    static func appScript(home: String) -> String {
        let quoted = CommandLauncher.shellQuote(RemoteServerLayout.appExecutable(home: home))
        return "test -x \(quoted) && printf 'present\\n'"
    }

    /// Checks that the agent is installed, loaded, *and* actually running. All
    /// three are distinct real states: a plist on disk that was never
    /// bootstrapped looks identical to a working service by file test alone,
    /// and a bootstrapped job can sit at `state = not running` indefinitely
    /// (launchd pends the spawn as "speculative" when the job is bootstrapped
    /// from a non-GUI context such as this SSH session). Both were observed on
    /// the real mini; registration alone would have reported a healthy server
    /// that never runs a single processing sweep.
    ///
    /// `grep -m1 "state = "` pins the match to the job's own top-level state:
    /// `launchctl print` also prints nested `state = ` lines for the job's
    /// endpoints, and an unanchored match could read one of those instead.
    static func launchAgentScript(home: String) -> String {
        let path = CommandLauncher.shellQuote(RemoteServerLayout.launchAgent(home: home))
        let label = CommandLauncher.shellQuote(RemoteServerLayout.launchAgentLabel)
        return """
        test -f \(path) || exit 1
        launchctl print "gui/$(id -u)/"\(label) 2>/dev/null | grep -m1 "state = " | grep -q "state = running" || exit 2
        printf 'running\\n'
        """
    }

    // MARK: Provisioning

    static func makeDirectoryScript(_ path: String) -> String {
        "mkdir -p " + CommandLauncher.shellQuote(path)
    }

    /// Builds the virtualenv from the discovered base interpreter and installs
    /// the helper package plus its pinned local-processing extras from the
    /// source this client just rsynced. `--upgrade` so re-running after a
    /// Damso update actually replaces the installed package.
    static func createEnvironmentScript(basePython: String, home: String) -> String {
        let base = CommandLauncher.shellQuote(basePython)
        let venv = CommandLauncher.shellQuote(RemoteServerLayout.virtualenvRoot(home: home))
        let python = CommandLauncher.shellQuote(RemoteServerLayout.virtualenvPython(home: home))
        let source = CommandLauncher.shellQuote(RemoteServerLayout.serverSourceRoot(home: home) + "[local-processing]")
        return """
        \(CommandLauncher.remotePathPrefix)
        export PATH
        \(base) -m venv \(venv) || exit 1
        \(python) -m pip install --upgrade pip || exit 1
        \(python) -m pip install --upgrade \(source) || exit 1
        \(python) -c 'import damso, mlx_whisper, sherpa_onnx; print("ready")'
        """
    }

    static func installModelsScript(interpreterPath: String, modelRoot: String) -> String {
        let interpreter = CommandLauncher.shellQuote(interpreterPath)
        let root = CommandLauncher.shellQuote(modelRoot)
        return "\(CommandLauncher.remotePathPrefix) \(interpreter) -m damso.model_setup --install --model-root \(root)"
    }

    /// Re-signs after transfer and reports the result. The bundle is ad-hoc
    /// signed with a stable designated requirement (see
    /// `scripts/install-local-app.sh`); rsync preserves that, but re-signing
    /// on arrival is idempotent and repairs a bundle whose signature the
    /// transfer disturbed, so the server's macOS keeps treating it as the same
    /// app identity across updates.
    static func finalizeAppScript(home: String) -> String {
        let bundle = CommandLauncher.shellQuote(RemoteServerLayout.appBundle(home: home))
        let requirement = "'=designated => identifier \"com.yansfil.damso\"'"
        return """
        codesign --force --sign - --identifier com.yansfil.damso --requirements \(requirement) \(bundle) >/dev/null 2>&1
        codesign --verify --deep --strict \(bundle) >/dev/null 2>&1 || exit 1
        printf 'installed\\n'
        """
    }

    /// Writes the plist from stdin rather than interpolating XML into a shell
    /// heredoc - the paths inside it contain spaces and the label contains
    /// dots, and piping keeps both out of shell tokenization entirely.
    static func writeLaunchAgentScript(home: String) -> String {
        let directory = CommandLauncher.shellQuote(home + "/Library/LaunchAgents")
        let logs = CommandLauncher.shellQuote(RemoteServerLayout.logDirectory(home: home))
        let path = CommandLauncher.shellQuote(RemoteServerLayout.launchAgent(home: home))
        return """
        mkdir -p \(directory) \(logs) || exit 1
        cat > \(path) || exit 1
        plutil -lint \(path) >/dev/null || exit 1
        printf 'written\\n'
        """
    }

    /// Ends a server instance that launchd does not manage. Bootstrapping the
    /// agent while such a process is alive would leave two servers sweeping
    /// the same store, and overwriting the bundle underneath a running app is
    /// worse still - both are real states, not hypotheticals: the mini was
    /// found running a server started by `open -a` (its LaunchAgent plist
    /// written but never bootstrapped), which is exactly what step 4 of the
    /// manual two-machine setup produces if the `launchctl` half is skipped.
    ///
    /// `pgrep -x` matches the process *name* only, so this can never match the
    /// SSH session's own shell - a `pgrep -f`/`pkill -f` on the argument text
    /// would, because the remote shell's argv contains this whole script.
    static let stopServerScript = """
    for pid in $(pgrep -x Damso 2>/dev/null); do
      case "$(ps -o args= -p "$pid" 2>/dev/null)" in
        *--server-role*) kill "$pid" 2>/dev/null ;;
      esac
    done
    printf 'stopped\\n'
    """

    /// `bootout` before `bootstrap` so re-running setup after changing the
    /// interpreter path actually reloads the job instead of silently keeping
    /// the old arguments; its failure is ignored because "not currently
    /// loaded" is the normal first-install case, not an error.
    static func loadLaunchAgentScript(home: String) -> String {
        let path = CommandLauncher.shellQuote(RemoteServerLayout.launchAgent(home: home))
        let label = CommandLauncher.shellQuote(RemoteServerLayout.launchAgentLabel)
        return """
        launchctl bootout "gui/$(id -u)/"\(label) >/dev/null 2>&1
        \(stopServerScript)
        launchctl bootstrap "gui/$(id -u)" \(path) || exit 1
        launchctl kickstart "gui/$(id -u)/"\(label) >/dev/null 2>&1
        attempt=0
        while [ "$attempt" -lt 20 ]; do
          if launchctl print "gui/$(id -u)/"\(label) 2>/dev/null | grep -m1 "state = " | grep -q "state = running"; then
            printf 'running\\n'
            exit 0
          fi
          sleep 1
          attempt=$((attempt + 1))
        done
        exit 2
        """
    }
}

/// Generates the server LaunchAgent. Kept pure and separate so its exact
/// contents are asserted in tests - a wrong `--local-python=` here is the
/// failure mode that silently broke every sweep-triggered run on the mini
/// before it was found by live testing.
enum RemoteLaunchAgentPlist {
    static func xml(home: String, interpreterPath: String) -> String {
        let arguments = [
            RemoteServerLayout.appExecutable(home: home),
            InstanceRole.serverRoleArgument,
            InstanceRole.localPythonArgumentPrefix + interpreterPath,
        ]
        let argumentXML = arguments
            .map { "        <string>" + escape($0) + "</string>" }
            .joined(separator: "\n")
        let logDirectory = RemoteServerLayout.logDirectory(home: home)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(escape(RemoteServerLayout.launchAgentLabel))</string>

            <key>ProgramArguments</key>
            <array>
        \(argumentXML)
            </array>

            <key>RunAtLoad</key>
            <true/>

            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>

            <key>StandardOutPath</key>
            <string>\(escape(logDirectory + "/server.log"))</string>

            <key>StandardErrorPath</key>
            <string>\(escape(logDirectory + "/server.error.log"))</string>
        </dict>
        </plist>

        """
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Runs preflight and provisioning against a *candidate* server, before that
/// server is saved as this Mac's store. Everything here is deliberately
/// independent of `RemoteExecutionConfiguration`: probing a host must never
/// require - or disturb - the connection this Mac is currently using.
struct RemoteSetupService: Sendable {
    let runner: RemoteSetupRunner
    /// The Python helper source shipped inside this app bundle, rsynced to the
    /// server during provisioning. Nil in a development build run straight
    /// from `swift run`, where no bundle resource exists; provisioning then
    /// reports the environment step as unfixable rather than half-installing.
    let bundledSourceDirectory: URL?

    init(
        runner: RemoteSetupRunner = .live,
        bundledSourceDirectory: URL? = RemoteSetupService.defaultBundledSourceDirectory()
    ) {
        self.runner = runner
        self.bundledSourceDirectory = bundledSourceDirectory
    }

    static func defaultBundledSourceDirectory(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent("server-src", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    // MARK: Probes

    private func runScript(host: String, _ script: String, input: Data? = nil) -> (output: String, status: Int32)? {
        guard let result = runner.execute(RemoteSetupCommands.ssh(host: host, script: script), input) else {
            return nil
        }
        let text = String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, result.terminationStatus)
    }

    /// Reads the server's architecture and home directory, or explains why it
    /// could not. Every other probe needs `home`, so this is always first.
    func connect(host: String) -> RemoteConnectionOutcome {
        guard let result = runScript(host: host, RemoteSetupCommands.connectionScript) else {
            return .unavailable(.failed(Loc.tr("Could not run ssh on this Mac.")))
        }
        guard result.status == 0 else {
            return .unavailable(.missing(Loc.tr("Could not reach this host over SSH.")))
        }
        let lines = result.output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard lines.count >= 2, !lines[1].isEmpty else {
            return .unavailable(.failed(Loc.tr("The host responded but did not report its home directory.")))
        }
        var facts = RemoteServerFacts(home: lines[1], architecture: lines[0], basePython: nil)
        if let python = runScript(host: host, RemoteSetupCommands.basePythonScript), python.status == 0, !python.output.isEmpty {
            facts.basePython = python.output
        }
        return .connected(facts)
    }

    func checkBasePython(facts: RemoteServerFacts) -> RemoteSetupStatus {
        guard let python = facts.basePython else {
            return .missing(Loc.tr("No Python 3.11 or newer found."))
        }
        return .satisfied(python)
    }

    func checkFfmpeg(host: String) -> RemoteSetupStatus {
        guard let result = runScript(host: host, RemoteSetupCommands.ffmpegScript), result.status == 0, !result.output.isEmpty else {
            return .missing(Loc.tr("Not installed."))
        }
        return .satisfied(result.output)
    }

    func checkStore(host: String, storeRoot: String) -> RemoteSetupStatus {
        guard let result = runScript(host: host, RemoteSetupCommands.storeScript(storeRoot: storeRoot)), result.status == 0 else {
            return .missing(Loc.tr("No meeting store at this path yet."))
        }
        return .satisfied(storeRoot)
    }

    func checkEnvironment(host: String, interpreterPath: String) -> RemoteSetupStatus {
        guard let result = runScript(host: host, RemoteSetupCommands.environmentScript(interpreterPath: interpreterPath)),
              result.status == 0 else {
            return .missing(Loc.tr("Processing packages are not installed."))
        }
        return .satisfied(interpreterPath)
    }

    func checkModels(host: String, interpreterPath: String, modelRoot: String) -> RemoteSetupStatus {
        let script = RemoteSetupCommands.modelsScript(interpreterPath: interpreterPath, modelRoot: modelRoot)
        guard let result = runScript(host: host, script), result.status == 0,
              let data = result.output.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(LocalModelSetupResult.self, from: data) else {
            return .missing(Loc.tr("Transcription and diarization models are not installed."))
        }
        guard decoded.ok, decoded.whisperReady == true, decoded.sherpaReady == true else {
            return .missing(decoded.errorCode ?? Loc.tr("Transcription and diarization models are not installed."))
        }
        return .satisfied(modelRoot)
    }

    func checkApp(host: String, home: String) -> RemoteSetupStatus {
        guard let result = runScript(host: host, RemoteSetupCommands.appScript(home: home)), result.status == 0 else {
            return .missing(Loc.tr("Damso is not installed on this Mac."))
        }
        return .satisfied(RemoteServerLayout.appBundle(home: home))
    }

    func checkLaunchAgent(host: String, home: String) -> RemoteSetupStatus {
        guard let result = runScript(host: host, RemoteSetupCommands.launchAgentScript(home: home)) else {
            return .missing(Loc.tr("Not registered."))
        }
        switch result.status {
        case 0: return .satisfied(RemoteServerLayout.launchAgentLabel)
        case 2: return .missing(Loc.tr("Registered but not running."))
        default: return .missing(Loc.tr("Not registered."))
        }
    }

    // MARK: Provisioning

    /// Copies this app's bundled helper source to the server and builds the
    /// virtualenv around it.
    func provisionEnvironment(host: String, facts: RemoteServerFacts) -> RemoteSetupStatus {
        guard let source = bundledSourceDirectory else {
            return .failed(Loc.tr("This build has no bundled helper package; install Damso with `make install-local-app` first."))
        }
        guard let basePython = facts.basePython else {
            return .failed(Loc.tr("No Python 3.11 or newer found."))
        }
        let destination = RemoteServerLayout.serverSourceRoot(home: facts.home)
        guard let made = runScript(host: host, RemoteSetupCommands.makeDirectoryScript(destination)), made.status == 0 else {
            return .failed(Loc.tr("Could not create the helper package directory."))
        }
        let rsyncArgv = RemoteSetupCommands.rsync(
            localDirectory: source.path,
            host: host,
            remoteDirectory: destination,
            delete: true
        )
        guard let copied = runner.execute(rsyncArgv, nil), copied.terminationStatus == 0 else {
            return .failed(Loc.tr("Could not copy the helper package to the server."))
        }
        let script = RemoteSetupCommands.createEnvironmentScript(basePython: basePython, home: facts.home)
        guard let installed = runScript(host: host, script), installed.status == 0 else {
            return .failed(Loc.tr("Installing the processing packages failed. Check the server's network connection."))
        }
        return .satisfied(RemoteServerLayout.virtualenvPython(home: facts.home))
    }

    func provisionModels(host: String, home: String, interpreterPath: String) -> RemoteSetupStatus {
        let modelRoot = RemoteServerLayout.modelRoot(home: home)
        let script = RemoteSetupCommands.installModelsScript(interpreterPath: interpreterPath, modelRoot: modelRoot)
        guard let result = runScript(host: host, script), result.status == 0 else {
            return .failed(Loc.tr("Downloading the local models failed. Check the server's network connection."))
        }
        return checkModels(host: host, interpreterPath: interpreterPath, modelRoot: modelRoot)
    }

    /// Transfers this Mac's own installed app bundle. Both machines are Apple
    /// Silicon (enforced by the connection step, since mlx-whisper only runs
    /// there at all), so the same binary is valid on the server and there is
    /// nothing to rebuild remotely - which is what removes Xcode and a repo
    /// checkout from the server's requirements entirely.
    func provisionApp(host: String, home: String, localAppBundle: URL) -> RemoteSetupStatus {
        guard FileManager.default.fileExists(atPath: localAppBundle.path) else {
            return .failed(Loc.tr("No installed Damso.app found on this Mac. Run `make install-local-app` first."))
        }
        let destination = RemoteServerLayout.appBundle(home: home)
        guard let made = runScript(host: host, RemoteSetupCommands.makeDirectoryScript(destination)), made.status == 0 else {
            return .failed(Loc.tr("Could not create the Applications directory on the server."))
        }
        // Replacing a bundle underneath a running instance corrupts it; the
        // LaunchAgent step starts the server again once the copy is signed.
        _ = runScript(host: host, RemoteSetupCommands.stopServerScript)
        let rsyncArgv = RemoteSetupCommands.rsync(
            localDirectory: localAppBundle.path,
            host: host,
            remoteDirectory: destination,
            delete: true
        )
        guard let copied = runner.execute(rsyncArgv, nil), copied.terminationStatus == 0 else {
            return .failed(Loc.tr("Could not copy Damso to the server."))
        }
        guard let finalized = runScript(host: host, RemoteSetupCommands.finalizeAppScript(home: home)), finalized.status == 0 else {
            return .failed(Loc.tr("Damso was copied but its signature could not be verified on the server."))
        }
        return .satisfied(destination)
    }

    func provisionLaunchAgent(host: String, home: String, interpreterPath: String) -> RemoteSetupStatus {
        let plist = RemoteLaunchAgentPlist.xml(home: home, interpreterPath: interpreterPath)
        let script = RemoteSetupCommands.writeLaunchAgentScript(home: home)
        guard let written = runScript(host: host, script, input: Data(plist.utf8)), written.status == 0 else {
            return .failed(Loc.tr("Could not write the background service definition."))
        }
        guard let loaded = runScript(host: host, RemoteSetupCommands.loadLaunchAgentScript(home: home)), loaded.status == 0 else {
            return .failed(Loc.tr("The background service was written but did not start."))
        }
        return .satisfied(RemoteServerLayout.launchAgentLabel)
    }

    static func defaultLocalAppBundle(fileManager: FileManager = .default) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications/Damso.app", isDirectory: true)
    }
}
