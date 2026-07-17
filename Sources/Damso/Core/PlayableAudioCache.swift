import Foundation

/// AVAudioPlayer cannot decode Ogg/Vorbis or Opus, which is what many legacy
/// and Plaud recordings use (`audio.ogg`). Playback for those records goes
/// through a one-time local ffmpeg transcode cached next to the original
/// (`playback-cache.m4a`); native formats play directly and nothing is ever
/// uploaded or modified in place.
enum PlayableAudioCache {
    static let unplayableExtensions: Set<String> = ["ogg", "oga", "opus", "webm"]
    static let cacheFileName = "playback-cache.m4a"

    static func isNativelyPlayable(_ url: URL) -> Bool {
        !unplayableExtensions.contains(url.pathExtension.lowercased())
    }

    static func cacheURL(for original: URL) -> URL {
        original.deletingLastPathComponent().appendingPathComponent(cacheFileName)
    }

    /// The URL that can be handed to AVAudioPlayer right now: the original for
    /// native formats, the cached transcode when it exists, nil when a
    /// transcode is still needed.
    static func existingPlayableURL(for original: URL) -> URL? {
        if isNativelyPlayable(original) { return original }
        let cache = cacheURL(for: original)
        return FileManager.default.fileExists(atPath: cache.path) ? cache : nil
    }

    /// Transcodes an unplayable original into the cache with ffmpeg (a
    /// documented prerequisite). Returns the playable URL, or nil when ffmpeg
    /// is unavailable or fails. Safe to call repeatedly; an existing cache is
    /// returned immediately.
    static func preparePlayableURL(for original: URL) async -> URL? {
        if let ready = existingPlayableURL(for: original) { return ready }
        let cache = cacheURL(for: original)
        let temporary = cache.deletingLastPathComponent()
            .appendingPathComponent(".playback-cache-\(UUID().uuidString).m4a")
        let succeeded = await Task.detached(priority: .utility) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                                 "-i", original.path, "-vn", "-c:a", "aac", "-b:a", "96k", temporary.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: temporary.path)
        }.value
        guard succeeded else {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
        do {
            if FileManager.default.fileExists(atPath: cache.path) {
                try FileManager.default.removeItem(at: cache)
            }
            try FileManager.default.moveItem(at: temporary, to: cache)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            return nil
        }
        return cache
    }
}
