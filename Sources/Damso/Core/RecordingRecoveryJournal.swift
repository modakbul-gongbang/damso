import Foundation

enum RecordingRecoveryStatus: String, Codable, Equatable, Sendable {
    case capturing
    case interrupted
    case stopped
    case failed
}

struct VerifiedRecordingFile: Codable, Equatable, Sendable {
    var relativePath: String
    var byteCount: Int64
}

struct RecordingRecoveryCheckpoint: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var status: RecordingRecoveryStatus
    var updatedAt: Date
    var files: [VerifiedRecordingFile]
    var failureCode: String?

    init(
        version: Int = Self.currentVersion,
        status: RecordingRecoveryStatus,
        updatedAt: Date = .now,
        files: [VerifiedRecordingFile] = [],
        failureCode: String? = nil
    ) {
        self.version = version
        self.status = status
        self.updatedAt = updatedAt
        self.files = files
        self.failureCode = failureCode
    }
}

enum RecordingRecoveryError: Error, Equatable {
    case unsafeAudioPath
    case invalidCheckpoint
}

/// Persists only the last known-good local audio files for an active recording.
/// A recovered session is deliberately interrupted, never complete, so the UI
/// can retain audio and ask the user whether to continue processing it.
final class RecordingRecoveryJournal {
    private let recordingDirectory: URL
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(recordingDirectory: URL, fileManager: FileManager = .default) {
        self.recordingDirectory = recordingDirectory.standardizedFileURL
        self.fileURL = recordingDirectory.appendingPathComponent("recording-recovery.json")
        self.fileManager = fileManager
        DateCoding.configure(encoder)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        DateCoding.configure(decoder)
    }

    func begin(files: CapturedAudioFiles) throws {
        _ = try normalizedRelativePath(for: files.microphone)
        _ = try normalizedRelativePath(for: files.systemAudio)
        try persist(RecordingRecoveryCheckpoint(status: .capturing))
    }

    @discardableResult
    func checkpoint(files: CapturedAudioFiles) throws -> RecordingRecoveryCheckpoint {
        var verified: [VerifiedRecordingFile] = []
        for file in [files.microphone, files.systemAudio] {
            let relativePath = try normalizedRelativePath(for: file)
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true, let size = values?.fileSize, size > 0 else { continue }
            verified.append(VerifiedRecordingFile(relativePath: relativePath, byteCount: Int64(size)))
        }
        let checkpoint = RecordingRecoveryCheckpoint(status: .capturing, files: verified.sorted { $0.relativePath < $1.relativePath })
        try persist(checkpoint)
        return checkpoint
    }

    @discardableResult
    func stop(files: CapturedAudioFiles) throws -> RecordingRecoveryCheckpoint {
        let active = try checkpoint(files: files)
        let stopped = RecordingRecoveryCheckpoint(status: .stopped, files: active.files)
        try persist(stopped)
        return stopped
    }

    func markFailure(code: String) throws {
        let current = try read() ?? RecordingRecoveryCheckpoint(status: .failed)
        try persist(RecordingRecoveryCheckpoint(status: .failed, files: current.files, failureCode: code))
    }

    /// Converts an uncleanly terminated capture into an explicit recovery state.
    /// It never claims that the meeting or its processing completed.
    @discardableResult
    func recoverAfterUnexpectedExit() throws -> RecordingRecoveryCheckpoint? {
        guard let checkpoint = try read() else { return nil }
        guard checkpoint.version == RecordingRecoveryCheckpoint.currentVersion else {
            throw RecordingRecoveryError.invalidCheckpoint
        }
        guard checkpoint.status == .capturing else { return checkpoint }
        let recovered = RecordingRecoveryCheckpoint(status: .interrupted, files: checkpoint.files, failureCode: "recording_interrupted")
        try persist(recovered)
        return recovered
    }

    func read() throws -> RecordingRecoveryCheckpoint? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        return try decoder.decode(RecordingRecoveryCheckpoint.self, from: Data(contentsOf: fileURL))
    }

    private func persist(_ checkpoint: RecordingRecoveryCheckpoint) throws {
        try fileManager.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        try encoder.encode(checkpoint).write(to: fileURL, options: .atomic)
    }

    private func normalizedRelativePath(for file: URL) throws -> String {
        let rootPath = recordingDirectory.path.hasSuffix("/") ? recordingDirectory.path : recordingDirectory.path + "/"
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { throw RecordingRecoveryError.unsafeAudioPath }
        let relativePath = String(path.dropFirst(rootPath.count))
        guard !relativePath.isEmpty, !relativePath.hasPrefix("../"), !relativePath.contains("/../") else {
            throw RecordingRecoveryError.unsafeAudioPath
        }
        return relativePath
    }
}
