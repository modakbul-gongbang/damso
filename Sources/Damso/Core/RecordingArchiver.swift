import Foundation

enum RecordingArchiverError: Error, Equatable {
    case launchFailed
    case nonZeroExit(Int32)
}

/// Packs one outbox record directory's contents into a tar.gz archive for
/// `POST /v1/recordings` (D-06, D-23). Shells out to the system `tar` rather
/// than hand-rolling the format - macOS ships bsdtar at this fixed path on
/// every supported OS version, and gzip-compressed tar is exactly what the
/// server's `tarfile.open(mode="r:gz")` expects.
enum RecordingArchiver {
    static func archive(directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        // -C changes into the directory first so archive members are
        // relative (meeting.json, not <uuid>/meeting.json) - the server
        // extracts directly into its own fresh staging directory and expects
        // `meeting.json` at the archive root.
        process.arguments = ["-czf", "-", "-C", directory.path, "."]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw RecordingArchiverError.launchFailed
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RecordingArchiverError.nonZeroExit(process.terminationStatus)
        }
        return data
    }
}
