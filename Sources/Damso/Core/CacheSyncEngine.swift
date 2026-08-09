import Foundation

/// Pulls the macOS client's metadata cache (R7) from the mini's canonical
/// store with one `rsync -a --delete` per run: cheap artifacts sync so
/// offline reads (list, transcript, summary, search) work without a
/// connection; audio and derived/transient state never do, by construction
/// of the include list below rather than by exclusion of everything else -
/// a name added to the canonical store that isn't in this list stays out of
/// the cache automatically instead of leaking in until someone remembers to
/// exclude it.
struct CacheSyncEngine {
    let launcher: CommandLauncher
    let cacheRoot: URL
    /// Defaults to the process-wide singleton; tests inject a fresh instance
    /// so a real "mini unreachable" outcome here never leaks into another
    /// test's `connectionStatus` expectations.
    let tracker: RemoteConnectivityTracker

    init(launcher: CommandLauncher = CommandLauncher(), cacheRoot: URL, tracker: RemoteConnectivityTracker = .shared) {
        self.launcher = launcher
        self.cacheRoot = cacheRoot
        self.tracker = tracker
    }

    /// Every filename rsync mirrors into the cache, applied at every
    /// directory depth (`Plaud/recordings/<stem>/...` and
    /// `Plaud/peoples/<slug>/...`). `.deleted-people.json` lives at the
    /// peoples root, not per-profile, but the same flat name-match still
    /// finds it. Deliberately excluded: audio (ogg/mp3/m4a/caf/wav),
    /// per-recording speaker-embeddings.npz, the derived `index.sqlite3`,
    /// and the server-only `.staging`/`.quarantine` transients.
    static let includedFileNames = [
        "meeting.json",
        "transcript.raw.json",
        "transcript.json",
        "transcript.md",
        "transcript.cleaned.json",
        "identification.json",
        "summary.json",
        "speaker_hints.json",
        "resolutions.yaml",
        "hint.json",
        "participants.json",
        "profile.md",
        "voice.npy",
        ".deleted-people.json",
    ]

    /// Runs one sync pass. Returns false without changing anything already
    /// on disk when remote execution isn't configured or the mini is
    /// unreachable - rsync's own per-file atomic replace (temp file then
    /// rename) means an interrupted run leaves every file it touched either
    /// fully updated or untouched, never half-written, so the next call
    /// (the next trigger point, R7) picks up exactly where this one left
    /// off with no separate resume bookkeeping.
    @discardableResult
    func sync() async -> Bool {
        guard case .remote(let host, _) = launcher.configuration.mode,
              let storeRoot = launcher.configuration.remoteStoreRootPath else {
            return false
        }
        do {
            try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        } catch {
            return false
        }
        let escapedRemoteRoot = storeRoot.replacingOccurrences(of: " ", with: "\\ ")
        var arguments = ["rsync", "-a", "--delete", CommandLauncher.rsyncRemoteShellArgument]
        arguments += ["--exclude=.staging/", "--exclude=.quarantine/", "--exclude=index.sqlite3"]
        arguments += ["--include=*/"]
        arguments += Self.includedFileNames.map { "--include=\($0)" }
        arguments += ["--exclude=*"]
        arguments += ["\(host):\(escapedRemoteRoot)/", cacheRoot.path + "/"]

        let succeeded = await Task.detached(priority: .utility) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            process.environment = ProcessRuntime.environment()
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        tracker.noteTransferResult(succeeded: succeeded)
        return succeeded
    }
}
