import Foundation

/// Pulls one on-demand audio file from the mini into the local metadata
/// cache when the canonical store is remote. Audio is deliberately excluded
/// from the periodic cache sync (R7) because it is large; this fetches only
/// the specific file playback or a speaker sample actually needs, the same
/// on-demand shape `PlayableAudioCache` already uses for its ffmpeg
/// transcode. A no-op when the store is local (the file is already wherever
/// `store.recordDirectoryURL` points) or already cached locally.
struct RemoteAudioFetcher {
    let launcher: CommandLauncher
    /// Defaults to the process-wide singleton; tests inject a fresh instance
    /// so a real "mini unreachable" outcome here never leaks into another
    /// test's `connectionStatus` expectations.
    let tracker: RemoteConnectivityTracker

    init(launcher: CommandLauncher = CommandLauncher(), tracker: RemoteConnectivityTracker = .shared) {
        self.launcher = launcher
        self.tracker = tracker
    }

    /// `localURL`/`remotePath` are resolved by the caller (typically via
    /// `store.recordDirectoryURL`/`recordDirectoryPath`) before crossing into
    /// the detached task, since `any MeetingStoring` is not `Sendable`.
    @discardableResult
    func ensureAvailable(localURL: URL, remotePath: String) async -> Bool {
        if FileManager.default.fileExists(atPath: localURL.path) {
            return true
        }
        guard case .remote(let host, _) = launcher.configuration.mode else {
            return false
        }
        let succeeded = await Task.detached(priority: .utility) {
            Self.pull(host: host, remotePath: remotePath, to: localURL)
        }.value
        tracker.noteTransferResult(succeeded: succeeded)
        return succeeded
    }

    /// rsync does not reliably shell-quote spaces in a remote-path argument
    /// itself; a literal backslash-space in the string is required, verified
    /// against the mini (`rsync -a "mini:Library/Application\ Support/..." ...`
    /// succeeds, an unescaped space does not) - the same pitfall as ssh's
    /// argument joining (FACT-ssh-remote-arg-space-splitting), one layer up.
    private static func pull(host: String, remotePath: String, to localURL: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return false
        }
        let escapedRemotePath = remotePath.replacingOccurrences(of: " ", with: "\\ ")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["rsync", "-a", CommandLauncher.rsyncRemoteShellArgument, "\(host):\(escapedRemotePath)", localURL.path]
        process.environment = ProcessRuntime.environment()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: localURL.path)
    }
}
