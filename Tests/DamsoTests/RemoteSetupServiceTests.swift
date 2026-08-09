import Foundation
import Testing
@testable import Damso

private func output(_ text: String, status: Int32 = 0) -> CommandLauncherOutput {
    CommandLauncherOutput(data: Data(text.utf8), terminationStatus: status)
}

/// Answers by matching on the remote script, which is always the last argv
/// element for an ssh call. Keeps each test's fake honest about *which*
/// command it is responding to instead of returning one canned answer.
private func runner(
    _ respond: @escaping @Sendable (_ argv: [String], _ input: Data?) -> CommandLauncherOutput?
) -> RemoteSetupRunner {
    RemoteSetupRunner(execute: respond)
}

private func service(_ respond: @escaping @Sendable ([String], Data?) -> CommandLauncherOutput?) -> RemoteSetupService {
    RemoteSetupService(runner: runner(respond), bundledSourceDirectory: nil)
}

// MARK: Escaping and argv shape

@Test
func sshHandsTheWholeScriptToTheRemoteShellAsOneArgumentWithFastFailOptions() {
    let argv = RemoteSetupCommands.ssh(host: "mini", script: "uname -m\nprintf '%s\\n' \"$HOME\"")

    #expect(argv[0] == "ssh")
    #expect(argv.contains("-o"))
    #expect(argv.contains("ConnectTimeout=5"))
    #expect(argv.contains("BatchMode=yes"))
    #expect(argv[argv.count - 2] == "mini")
    // A multi-line script must survive as exactly one argv element: ssh joins
    // everything after the host with spaces and re-tokenizes it remotely, so a
    // split here would silently run only the first line.
    #expect(argv.last == "uname -m\nprintf '%s\\n' \"$HOME\"")
}

@Test
func rsyncEscapesSpacesOnlyOnTheRemoteSideOfTheTransfer() {
    let remote = RemoteSetupCommands.rsyncRemotePath(host: "mini", path: "/Volumes/DamsoMini/Library/Application Support/Damso")
    // macOS's bundled openrsync fails outright ("server receiver mode requires
    // two argument") on an unescaped space in a remote path.
    #expect(remote == "mini:/Volumes/DamsoMini/Library/Application\\ Support/Damso")

    let argv = RemoteSetupCommands.rsync(
        localDirectory: "/Volumes/Laptop/Library/Application Support/Damso/x",
        host: "mini",
        remoteDirectory: "/Volumes/DamsoMini/Library/Application Support/Damso/x",
        delete: true
    )
    // The local path is its own argv element and never reaches a shell, so it
    // must keep its literal spaces.
    #expect(argv.contains("/Volumes/Laptop/Library/Application Support/Damso/x/"))
    #expect(argv.contains("mini:/Volumes/DamsoMini/Library/Application\\ Support/Damso/x/"))
    #expect(argv.contains("--delete"))
    #expect(argv.contains(CommandLauncher.rsyncRemoteShellArgument))
}

@Test
func rsyncOmitsDeleteWhenNotAskedForIt() {
    let argv = RemoteSetupCommands.rsync(localDirectory: "/a", host: "mini", remoteDirectory: "/b", delete: false)
    #expect(!argv.contains("--delete"))
    // Trailing slashes on both sides copy contents, not the directory nested
    // one level deeper.
    #expect(argv.contains("/a/"))
    #expect(argv.contains("mini:/b/"))
}

@Test
func noProbeScriptUsesAGlobBecauseZshAbortsTheWholeCommandOnNoMatch() {
    // A remote login shell on macOS is zsh, whose default `nomatch` kills the
    // entire command line when any pattern matches nothing - so one missing
    // prefix would take every later line of a probe down with it.
    let scripts = [
        RemoteSetupCommands.connectionScript,
        RemoteSetupCommands.basePythonScript,
        RemoteSetupCommands.ffmpegScript,
        RemoteSetupCommands.storeScript(storeRoot: "/store"),
        RemoteSetupCommands.environmentScript(interpreterPath: "/venv/bin/python3"),
        RemoteSetupCommands.appScript(home: "/Volumes/DamsoMini"),
        RemoteSetupCommands.launchAgentScript(home: "/Volumes/DamsoMini"),
    ]
    for script in scripts {
        #expect(!script.contains("*"), "probe script must not contain a glob: \(script)")
        #expect(!script.contains("?("))
    }
}

@Test
func theBasePythonProbeQuotesEveryCandidateAndInsistsOn311OrNewer() {
    let script = RemoteSetupCommands.basePythonScript
    for candidate in RemoteSetupCommands.basePythonCandidates {
        #expect(script.contains(CommandLauncher.shellQuote(candidate)))
    }
    #expect(script.contains("sys.version_info >= (3, 11)"))
    // The system Python is last so a Homebrew interpreter always wins, and it
    // only qualifies at all if a future macOS ships 3.11+.
    #expect(RemoteSetupCommands.basePythonCandidates.last == "/usr/bin/python3")
}

@Test
func theStoreProbeLooksForTheRecordTreeRatherThanAnEmptyDirectory() {
    let script = RemoteSetupCommands.storeScript(storeRoot: "/Volumes/DamsoMini/Library/Application Support/Damso")
    // An empty `Damso` directory is exactly what a prematurely-launched server
    // app creates; treating that as a real store would hide the one ordering
    // mistake this check exists to catch.
    #expect(script.contains("Plaud/recordings"))
    #expect(script.contains(CommandLauncher.shellQuote("/Volumes/DamsoMini/Library/Application Support/Damso/Plaud/recordings")))
}

@Test
func everyRemoteScriptShellQuotesPathsThatContainSpaces() {
    let home = "/Volumes/DamsoMini"
    let interpreter = RemoteServerLayout.virtualenvPython(home: home)
    #expect(interpreter.contains(" "), "the support root has a space, which is the whole point of quoting")

    let scripts = [
        RemoteSetupCommands.environmentScript(interpreterPath: interpreter),
        RemoteSetupCommands.modelsScript(interpreterPath: interpreter, modelRoot: RemoteServerLayout.modelRoot(home: home)),
        RemoteSetupCommands.installModelsScript(interpreterPath: interpreter, modelRoot: RemoteServerLayout.modelRoot(home: home)),
        RemoteSetupCommands.createEnvironmentScript(basePython: "/opt/homebrew/bin/python3.12", home: home),
        RemoteSetupCommands.writeLaunchAgentScript(home: home),
        RemoteSetupCommands.loadLaunchAgentScript(home: home),
        RemoteSetupCommands.makeDirectoryScript(RemoteServerLayout.serverSourceRoot(home: home)),
    ]
    for script in scripts {
        #expect(script.contains(CommandLauncher.shellQuote(interpreter)) || !script.contains(interpreter),
                "an interpreter path appearing unquoted would split on its space: \(script)")
    }
}

// MARK: Layout

@Test
func everyServerPathIsDerivedFromTheHomeDirectoryTheServerReported() {
    let home = "/Volumes/DamsoMini"
    #expect(RemoteServerLayout.supportRoot(home: home) == "/Volumes/DamsoMini/Library/Application Support/Damso")
    #expect(RemoteServerLayout.virtualenvPython(home: home) == "/Volumes/DamsoMini/Library/Application Support/Damso/server-venv/bin/python3")
    #expect(RemoteServerLayout.serverSourceRoot(home: home) == "/Volumes/DamsoMini/Library/Application Support/Damso/server-src")
    #expect(RemoteServerLayout.modelRoot(home: home) == "/Volumes/DamsoMini/Library/Application Support/Damso/Models")
    #expect(RemoteServerLayout.appExecutable(home: home) == "/Volumes/DamsoMini/Applications/Damso.app/Contents/MacOS/Damso")
    #expect(RemoteServerLayout.launchAgent(home: home) == "/Volumes/DamsoMini/Library/LaunchAgents/com.yansfil.damso.server.plist")
    // The account name on the server is routinely not the one on this Mac, so
    // nothing may fall back to a home other than the one passed in.
    #expect(RemoteServerLayout.supportRoot(home: "/Volumes/OtherMini").hasPrefix("/Volumes/OtherMini/"))
}

// MARK: LaunchAgent

@Test
func theGeneratedLaunchAgentCarriesBothLaunchArgumentsThatDefineAServerInstance() {
    let plist = RemoteLaunchAgentPlist.xml(
        home: "/Volumes/DamsoMini",
        interpreterPath: "/Volumes/DamsoMini/Library/Application Support/Damso/server-venv/bin/python3"
    )
    #expect(plist.contains("<string>/Volumes/DamsoMini/Applications/Damso.app/Contents/MacOS/Damso</string>"))
    #expect(plist.contains("<string>--server-role</string>"))
    // Omitting --local-python is the exact bug that silently broke every
    // sweep-triggered run on the real mini: a bare `python3` resolves to the
    // system interpreter, which has none of the processing dependencies.
    #expect(plist.contains("<string>--local-python=/Volumes/DamsoMini/Library/Application Support/Damso/server-venv/bin/python3</string>"))
    #expect(plist.contains("<key>RunAtLoad</key>"))
    #expect(plist.contains("<key>KeepAlive</key>"))
    #expect(plist.contains("com.yansfil.damso.server"))
}

@Test
func theGeneratedLaunchAgentEscapesXMLSoAnAmpersandInAPathCannotBreakThePlist() {
    let plist = RemoteLaunchAgentPlist.xml(home: "/Volumes/a&b", interpreterPath: "/usr/bin/<python>")
    #expect(plist.contains("/Volumes/a&amp;b/Applications/Damso.app/Contents/MacOS/Damso"))
    #expect(plist.contains("&lt;python&gt;"))
    #expect(!plist.contains("a&b"))
}

// MARK: Probes against a fake server

@Test
func connectReportsTheArchitectureAndHomeDirectoryTheServerPrinted() {
    let subject = service { argv, _ in
        let script = argv.last ?? ""
        if script == RemoteSetupCommands.connectionScript {
            return output("arm64\n/Volumes/DamsoMini\n")
        }
        if script == RemoteSetupCommands.basePythonScript {
            return output("/opt/homebrew/bin/python3.12\n")
        }
        return output("", status: 1)
    }

    guard case .connected(let facts) = subject.connect(host: "mini") else {
        Issue.record("expected a connected outcome")
        return
    }
    #expect(facts.home == "/Volumes/DamsoMini")
    #expect(facts.architecture == "arm64")
    #expect(facts.isAppleSilicon)
    #expect(facts.basePython == "/opt/homebrew/bin/python3.12")
}

@Test
func connectStillSucceedsWhenTheServerHasNoUsablePythonSoTheChecklistCanSayWhichStepFailed() {
    let subject = service { argv, _ in
        argv.last == RemoteSetupCommands.connectionScript ? output("arm64\n/Volumes/DamsoMini\n") : output("", status: 1)
    }

    guard case .connected(let facts) = subject.connect(host: "mini") else {
        Issue.record("a missing Python must not be reported as an unreachable host")
        return
    }
    #expect(facts.basePython == nil)
    #expect(subject.checkBasePython(facts: facts) == .missing(Loc.tr("No Python 3.11 or newer found.")))
}

@Test
func anUnreachableHostIsReportedAsMissingRatherThanAsALocalFailure() {
    let subject = service { _, _ in output("ssh: connect to host mini port 22: Host is down", status: 255) }

    guard case .unavailable(let status) = subject.connect(host: "mini") else {
        Issue.record("expected an unavailable outcome")
        return
    }
    #expect(status == .missing(Loc.tr("Could not reach this host over SSH.")))
}

@Test
func aHostThatCannotBeProbedAtAllIsDistinguishedFromOneThatAnswered() {
    // `nil` means the ssh binary itself never ran on this Mac, which is a
    // different problem from a server that answered with an error.
    let subject = service { _, _ in nil }

    guard case .unavailable(let status) = subject.connect(host: "mini") else {
        Issue.record("expected an unavailable outcome")
        return
    }
    #expect(status == .failed(Loc.tr("Could not run ssh on this Mac.")))
}

@Test
func aTruncatedConnectionResponseIsNotMistakenForAValidHomeDirectory() {
    let subject = service { argv, _ in
        argv.last == RemoteSetupCommands.connectionScript ? output("arm64\n") : output("", status: 1)
    }

    guard case .unavailable(let status) = subject.connect(host: "mini") else {
        Issue.record("expected an unavailable outcome")
        return
    }
    #expect(status == .failed(Loc.tr("The host responded but did not report its home directory.")))
}

@Test
func aRegisteredButUnloadedBackgroundServiceIsNotReportedAsSimplyMissing() {
    // Exit 2 means the plist is on disk but launchctl has no such job: the
    // server would look installed while never running a processing sweep.
    let stalled = service { _, _ in output("", status: 2) }
    #expect(stalled.checkLaunchAgent(host: "mini", home: "/Volumes/DamsoMini") == .missing(Loc.tr("Registered but not running.")))

    let absent = service { _, _ in output("", status: 1) }
    #expect(absent.checkLaunchAgent(host: "mini", home: "/Volumes/DamsoMini") == .missing(Loc.tr("Not registered.")))

    let loaded = service { _, _ in output("loaded\n") }
    #expect(loaded.checkLaunchAgent(host: "mini", home: "/Volumes/DamsoMini").isSatisfied)
}

@Test
func modelsCountAsReadyOnlyWhenBothWhisperAndSherpaReportReady() {
    let both = service { _, _ in output("{\"ok\": true, \"whisper_ready\": true, \"sherpa_ready\": true}") }
    #expect(both.checkModels(host: "mini", interpreterPath: "/p", modelRoot: "/m").isSatisfied)

    // A half-finished download is the realistic interrupted-install state and
    // must not pass, or the first meeting fails deep inside processing.
    let partial = service { _, _ in output("{\"ok\": true, \"whisper_ready\": true, \"sherpa_ready\": false}") }
    #expect(!partial.checkModels(host: "mini", interpreterPath: "/p", modelRoot: "/m").isSatisfied)

    let garbage = service { _, _ in output("not json") }
    #expect(!garbage.checkModels(host: "mini", interpreterPath: "/p", modelRoot: "/m").isSatisfied)
}

@Test
func aMissingProcessingEnvironmentIsReportedFromTheInterpreterImportCheck() {
    let ready = service { _, _ in output("ready\n") }
    #expect(ready.checkEnvironment(host: "mini", interpreterPath: "/venv/bin/python3") == .satisfied("/venv/bin/python3"))

    let missing = service { _, _ in output("ModuleNotFoundError: No module named 'mlx_whisper'", status: 1) }
    #expect(missing.checkEnvironment(host: "mini", interpreterPath: "/venv/bin/python3")
        == .missing(Loc.tr("Processing packages are not installed.")))
}

// MARK: Provisioning guards

@Test
func provisioningTheEnvironmentRefusesWhenThisBuildShipsNoHelperPackage() {
    // A `swift run` build has no bundle resource; half-installing from nothing
    // would leave a broken virtualenv behind.
    let subject = RemoteSetupService(runner: runner { _, _ in output("") }, bundledSourceDirectory: nil)
    let facts = RemoteServerFacts(home: "/Volumes/DamsoMini", architecture: "arm64", basePython: "/opt/homebrew/bin/python3.12")

    let status = subject.provisionEnvironment(host: "mini", facts: facts)
    #expect(status == .failed(Loc.tr("This build has no bundled helper package; install Damso with `make install-local-app` first.")))
}

@Test
func provisioningTheAppRefusesWhenThisMacHasNoInstalledBundleToCopy() {
    let subject = service { _, _ in output("") }
    let missing = URL(fileURLWithPath: "/nonexistent/Damso.app")

    let status = subject.provisionApp(host: "mini", home: "/Volumes/DamsoMini", localAppBundle: missing)
    #expect(status == .failed(Loc.tr("No installed Damso.app found on this Mac. Run `make install-local-app` first.")))
}

@Test
func theBackgroundServiceIsWrittenFromStdinRatherThanInterpolatedIntoTheShell() {
    let box = CapturedInput()
    let subject = RemoteSetupService(
        runner: runner { argv, input in
            if let input, argv.last == RemoteSetupCommands.writeLaunchAgentScript(home: "/Volumes/DamsoMini") {
                box.store(String(decoding: input, as: UTF8.self))
                return output("written\n")
            }
            return output("loaded\n")
        },
        bundledSourceDirectory: nil
    )

    let status = subject.provisionLaunchAgent(
        host: "mini",
        home: "/Volumes/DamsoMini",
        interpreterPath: "/Volumes/DamsoMini/Library/Application Support/Damso/server-venv/bin/python3"
    )

    #expect(status.isSatisfied)
    let written = box.value ?? ""
    #expect(written.contains("<key>Label</key>"))
    #expect(written.contains("--server-role"))
    // The plist never appears in the script text itself, so its spaces and
    // angle brackets are never exposed to shell tokenization.
    #expect(!RemoteSetupCommands.writeLaunchAgentScript(home: "/Volumes/DamsoMini").contains("<plist"))
}

@Test
func aBackgroundServiceThatWritesButFailsToStartIsReportedAsAFailureNotASuccess() {
    let subject = RemoteSetupService(
        runner: runner { argv, _ in
            argv.last == RemoteSetupCommands.loadLaunchAgentScript(home: "/Volumes/DamsoMini")
                ? output("", status: 2)
                : output("written\n")
        },
        bundledSourceDirectory: nil
    )

    let status = subject.provisionLaunchAgent(host: "mini", home: "/Volumes/DamsoMini", interpreterPath: "/p")
    #expect(status == .failed(Loc.tr("The background service was written but did not start.")))
}

@Test
func reloadingTheBackgroundServiceBootsItOutFirstSoChangedArgumentsActuallyTakeEffect() {
    let script = RemoteSetupCommands.loadLaunchAgentScript(home: "/Volumes/DamsoMini")
    guard let boot = script.range(of: "launchctl bootout"),
          let strap = script.range(of: "launchctl bootstrap") else {
        Issue.record("both launchctl calls must be present")
        return
    }
    #expect(boot.lowerBound < strap.lowerBound)
    // A first install has nothing to boot out, so that failure is expected and
    // must not abort the script.
    #expect(script.contains("launchctl bootout \"gui/$(id -u)/\"'com.yansfil.damso.server' >/dev/null 2>&1"))
}

@Test
func anUnmanagedServerIsStoppedBeforeBootstrappingSoTwoNeverSweepTheSameStore() {
    let script = RemoteSetupCommands.loadLaunchAgentScript(home: "/Volumes/DamsoMini")
    guard let stop = script.range(of: "pgrep -x Damso"),
          let strap = script.range(of: "launchctl bootstrap") else {
        Issue.record("the stop step must be part of the load script")
        return
    }
    // A server started by `open -a` is invisible to `launchctl bootout`, so
    // bootstrapping without this leaves two servers running at once - the real
    // state the mini was found in.
    #expect(stop.lowerBound < strap.lowerBound)
}

@Test
func theBackgroundServiceProbeRequiresARunningJobNotMerelyARegisteredOne() {
    let script = RemoteSetupCommands.launchAgentScript(home: "/Volumes/DamsoMini")
    // launchd pends the spawn as "speculative" when a job is bootstrapped from
    // a non-GUI context like an SSH session, leaving it registered at
    // `state = not running` indefinitely - observed on the real mini, where a
    // registration-only check reported a healthy server that had run 0 times.
    #expect(script.contains("state = running"))
    #expect(script.contains("test -f"))
}

@Test
func loadingTheBackgroundServiceKickstartsItAndWaitsForItToActuallyReachRunning() {
    let script = RemoteSetupCommands.loadLaunchAgentScript(home: "/Volumes/DamsoMini")
    #expect(script.contains("launchctl kickstart"))
    #expect(script.contains("state = running"))
    guard let strap = script.range(of: "launchctl bootstrap"),
          let kick = script.range(of: "launchctl kickstart") else {
        Issue.record("bootstrap and kickstart must both be present")
        return
    }
    #expect(strap.lowerBound < kick.lowerBound)
    // Reporting success the instant bootstrap returns is what hid the pended
    // spawn; the script has to observe the running state before claiming it.
    #expect(script.contains("exit 2"))
}

@Test
func stoppingTheServerMatchesOnProcessNameSoItCanNeverKillTheSshSessionItRunsIn() {
    let script = RemoteSetupCommands.stopServerScript
    // The remote shell's own argv contains this entire script, so any
    // `pgrep -f`/`pkill -f` over the argument text would match - and kill -
    // the session running it.
    #expect(script.contains("pgrep -x Damso"))
    #expect(!script.contains("pgrep -f"))
    #expect(!script.contains("pkill"))
    // Name alone is not enough to be sure it is a server: confirm the role.
    #expect(script.contains("--server-role"))
}

/// Small lock box so a `@Sendable` fake can record what it was handed.
private final class CapturedInput: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func store(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        stored = value
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
