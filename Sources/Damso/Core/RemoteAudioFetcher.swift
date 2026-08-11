import Foundation

/// Pulls one on-demand audio file from the server daemon (D-06, D-15) when
/// playback or a speaker sample needs it. Audio is deliberately excluded
/// from the periodic changes sync because it is large; this fetches only the
/// specific file needed, the same on-demand shape `PlayableAudioCache`
/// already uses for its ffmpeg transcode. A no-op when the file is already
/// cached locally (in local mode that is always true - the "cache" is the
/// real store).
struct RemoteAudioFetcher {
    let client: DamsoHTTPClient
    let tracker: RemoteConnectivityTracker

    init(client: DamsoHTTPClient = DamsoHTTPClient(), tracker: RemoteConnectivityTracker = .shared) {
        self.client = client
        self.tracker = tracker
    }

    /// `stem`/`filename` name the file on the server; `localURL` is where it
    /// should land on this Mac.
    @discardableResult
    func ensureAvailable(localURL: URL, stem: String, filename: String) async -> Bool {
        if FileManager.default.fileExists(atPath: localURL.path) {
            return true
        }
        let succeeded = await Task.detached(priority: .utility) { [client] in
            (try? client.downloadFile(stem: stem, filename: filename, to: localURL)) != nil
        }.value
        tracker.noteTransferResult(succeeded: succeeded)
        return succeeded
    }
}
