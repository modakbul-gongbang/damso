import Foundation

enum JobKind: String, Codable, Sendable {
    case transcription
    case speakerReview
    case summary
    case plaudSync
    case migration
    case restore
}

enum DurableJobState: String, Codable, Sendable {
    case queued
    case running
    case awaitingExplicitRetry
    case cancelled
    case complete
    case failed

    var isTerminal: Bool {
        switch self {
        case .cancelled, .complete, .failed:
            true
        default:
            false
        }
    }
}

struct JobCheckpoint: Codable, Equatable, Sendable {
    var stage: ProcessingStage
    var updatedAt: Date
    var artifactChecksum: String?
}

struct DurableJob: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var meetingStem: String?
    var kind: JobKind
    var state: DurableJobState
    var checkpoint: JobCheckpoint?
    var attemptCount: Int
    var startedAt: Date?
    var updatedAt: Date
    var lastErrorCode: String?

    init(id: UUID = UUID(), meetingStem: String? = nil, kind: JobKind, state: DurableJobState = .queued, checkpoint: JobCheckpoint? = nil, attemptCount: Int = 0, startedAt: Date? = nil, updatedAt: Date = .now, lastErrorCode: String? = nil) {
        self.id = id
        self.meetingStem = meetingStem
        self.kind = kind
        self.state = state
        self.checkpoint = checkpoint
        self.attemptCount = attemptCount
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.lastErrorCode = lastErrorCode
    }
}

enum DurableJobQueueError: Error, Equatable {
    case alreadyRunning
    case jobNotFound
    case invalidTransition
}

final class DurableJobQueue {
    private let fileURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var jobs: [DurableJob]

    init(fileURL: URL, fileManager: FileManager = .default) throws {
        self.fileURL = fileURL
        self.fileManager = fileManager
        DateCoding.configure(encoder)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        DateCoding.configure(decoder)
        if fileManager.fileExists(atPath: fileURL.path) {
            self.jobs = try decoder.decode([DurableJob].self, from: Data(contentsOf: fileURL))
        } else {
            self.jobs = []
        }
    }

    func all() -> [DurableJob] {
        jobs.sorted { $0.updatedAt < $1.updatedAt }
    }

    @discardableResult
    func enqueue(meetingStem: String? = nil, kind: JobKind) throws -> DurableJob {
        if let existing = jobs.first(where: { $0.meetingStem == meetingStem && $0.kind == kind && !$0.state.isTerminal && $0.state != .awaitingExplicitRetry }) {
            return existing
        }
        let job = DurableJob(meetingStem: meetingStem, kind: kind)
        jobs.append(job)
        try persist()
        return job
    }

    func nextRunnable(recordingIsActive: Bool) throws -> DurableJob? {
        guard !recordingIsActive else { return nil }
        guard !jobs.contains(where: { $0.state == .running }) else { throw DurableJobQueueError.alreadyRunning }
        guard let index = jobs.firstIndex(where: { $0.state == .queued }) else { return nil }
        jobs[index].state = .running
        jobs[index].attemptCount += 1
        jobs[index].startedAt = .now
        jobs[index].updatedAt = .now
        try persist()
        return jobs[index]
    }

    func checkpoint(_ jobID: UUID, stage: ProcessingStage, artifactChecksum: String? = nil) throws {
        let index = try index(of: jobID)
        guard jobs[index].state == .running else { throw DurableJobQueueError.invalidTransition }
        jobs[index].checkpoint = JobCheckpoint(stage: stage, updatedAt: .now, artifactChecksum: artifactChecksum)
        jobs[index].updatedAt = .now
        try persist()
    }

    func finish(_ jobID: UUID) throws {
        let index = try index(of: jobID)
        guard jobs[index].state == .running else { throw DurableJobQueueError.invalidTransition }
        jobs[index].state = .complete
        jobs[index].updatedAt = .now
        try persist()
    }

    func fail(_ jobID: UUID, errorCode: String) throws {
        let index = try index(of: jobID)
        guard jobs[index].state == .running else { throw DurableJobQueueError.invalidTransition }
        jobs[index].state = .failed
        jobs[index].lastErrorCode = errorCode
        jobs[index].updatedAt = .now
        try persist()
    }

    func cancel(_ jobID: UUID) throws {
        let index = try index(of: jobID)
        guard !jobs[index].state.isTerminal else { throw DurableJobQueueError.invalidTransition }
        jobs[index].state = .cancelled
        jobs[index].updatedAt = .now
        try persist()
    }

    func retry(_ jobID: UUID) throws {
        let index = try index(of: jobID)
        guard jobs[index].state == .awaitingExplicitRetry || jobs[index].state == .failed else {
            throw DurableJobQueueError.invalidTransition
        }
        jobs[index].state = .queued
        jobs[index].lastErrorCode = nil
        jobs[index].updatedAt = .now
        try persist()
    }

    func recoverAfterUnexpectedExit() throws -> [DurableJob] {
        var recovered: [DurableJob] = []
        for index in jobs.indices where jobs[index].state == .running {
            if jobs[index].kind == .summary {
                jobs[index].state = .awaitingExplicitRetry
                jobs[index].lastErrorCode = "external_cli_completion_unknown"
            } else {
                jobs[index].state = .queued
            }
            jobs[index].updatedAt = .now
            recovered.append(jobs[index])
        }
        if !recovered.isEmpty { try persist() }
        return recovered
    }

    private func index(of jobID: UUID) throws -> Int {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { throw DurableJobQueueError.jobNotFound }
        return index
    }

    private func persist() throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(jobs).write(to: fileURL, options: .atomic)
    }
}
