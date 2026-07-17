import Foundation

struct ExternalSyncCheckpoint: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var schedulerState: SyncSchedulerState
    var importIndex: SyncImportIndex
    /// Recording-time watermark: everything up to and including this start
    /// time has been imported (or intentionally passed). The next run lists
    /// from here, capped to the engine's catch-up window (7 days).
    var syncedThrough: Date?
    var updatedAt: Date

    init(
        version: Int = Self.currentVersion,
        schedulerState: SyncSchedulerState,
        importIndex: SyncImportIndex,
        syncedThrough: Date? = nil,
        updatedAt: Date = .now
    ) {
        self.version = version
        self.schedulerState = schedulerState
        self.importIndex = importIndex
        self.syncedThrough = syncedThrough
        self.updatedAt = updatedAt
    }
}

enum ExternalSyncCheckpointStoreError: Error, Equatable {
    case unsupportedVersion
}

/// Keeps scheduler state, per-file import outcomes, and the sync watermark on
/// the local store, one file per provider. A malformed or unwritable
/// checkpoint must block sync rather than cause an unbounded retry or a
/// duplicate import after the next launch.
final class ExternalSyncCheckpointStore: @unchecked Sendable {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        DateCoding.configure(encoder)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        DateCoding.configure(decoder)
    }

    /// Canonical per-provider checkpoint location under the store root, so
    /// the watermark follows the library if the user relocates it.
    static func fileURL(storeRoot: URL, providerID: String) -> URL {
        storeRoot
            .appendingPathComponent(".external-sync", isDirectory: true)
            .appendingPathComponent("\(providerID).json")
    }

    func load() throws -> ExternalSyncCheckpoint? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let checkpoint = try decoder.decode(ExternalSyncCheckpoint.self, from: Data(contentsOf: fileURL))
        guard checkpoint.version == ExternalSyncCheckpoint.currentVersion else {
            throw ExternalSyncCheckpointStoreError.unsupportedVersion
        }
        return checkpoint
    }

    func save(_ checkpoint: ExternalSyncCheckpoint) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(checkpoint).write(to: fileURL, options: .atomic)
    }
}
