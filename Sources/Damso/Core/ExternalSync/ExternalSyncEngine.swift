import Foundation

enum ExternalSyncRunStatus: Equatable, Sendable {
    case idle
    case deferredForRecording
    case waitingForReauthentication
    case backingOff(Date)
    case alreadyRunning
    case notInstalled
    case completed(imported: Int, retryableFailures: Int)
    case authenticationExpired
    case transientFailure
    case statePersistenceFailed
}

/// Snapshot of one provider's durable sync state for UI rendering.
struct ExternalSyncEngineSnapshot: Equatable, Sendable {
    var authState: SyncAuthState
    var lastSuccessfulRun: Date?
    var statePersistenceFailed: Bool
}

/// Per-provider sync orchestration: window policy (first run imports the last
/// 7 days, catch-up after re-enable is capped at 7 days), per-run
/// serialization, contiguous watermark advance, and per-file retry. Downloads
/// land in a private temporary directory and reach the meeting store only
/// through the injected import sink's validate-then-atomic-move contract, so
/// a partial file can never appear in the meeting list.
actor ExternalSyncEngine {
    static let catchUpWindow: TimeInterval = 7 * 24 * 60 * 60

    /// Validates the downloaded audio and commits one meeting record. Throws
    /// to reject the file; the engine then discards it and retries on the
    /// next sync without advancing the watermark past it.
    typealias ImportSink = @Sendable (_ recording: ExternalRecording, _ audioFile: URL) async throws -> Void

    private let provider: any ExternalSyncProvider
    private let scheduler: SyncScheduler
    private let checkpointStore: ExternalSyncCheckpointStore?
    private let importSink: ImportSink
    private let fileManager: FileManager

    private var state: SyncSchedulerState
    private var importIndex: SyncImportIndex
    private var syncedThrough: Date?
    private var statePersistenceFailed = false
    private var isRunning = false

    init(
        provider: any ExternalSyncProvider,
        scheduler: SyncScheduler = SyncScheduler(),
        checkpointStore: ExternalSyncCheckpointStore? = nil,
        fileManager: FileManager = .default,
        importSink: @escaping ImportSink
    ) {
        self.provider = provider
        self.scheduler = scheduler
        self.checkpointStore = checkpointStore
        self.fileManager = fileManager
        self.importSink = importSink
        if let checkpointStore {
            do {
                let checkpoint = try checkpointStore.load()
                state = checkpoint?.schedulerState ?? .initial
                importIndex = checkpoint?.importIndex ?? SyncImportIndex()
                syncedThrough = checkpoint?.syncedThrough
            } catch {
                state = .initial
                importIndex = SyncImportIndex()
                syncedThrough = nil
                statePersistenceFailed = true
            }
        } else {
            state = .initial
            importIndex = SyncImportIndex()
            syncedThrough = nil
        }
    }

    var snapshot: ExternalSyncEngineSnapshot {
        ExternalSyncEngineSnapshot(
            authState: state.authState,
            lastSuccessfulRun: state.lastSuccessfulRun,
            statePersistenceFailed: statePersistenceFailed
        )
    }

    /// Non-mutating preview of what a poll would do right now, so the UI can
    /// decide whether to show run progress before awaiting the poll.
    func nextDecision(now: Date = .now, recordingIsActive: Bool) -> SyncScheduleDecision {
        scheduler.decision(for: state, now: now, recordingIsActive: recordingIsActive)
    }

    /// Hourly tick entry point: the scheduler decides whether this tick runs,
    /// waits, or backs off. Sleep/wake catch-up falls out of the decision.
    func poll(now: Date = .now, recordingIsActive: Bool) async -> ExternalSyncRunStatus {
        guard !statePersistenceFailed else { return .statePersistenceFailed }
        switch scheduler.decision(for: state, now: now, recordingIsActive: recordingIsActive) {
        case .idle:
            return .idle
        case .waitForRecordingToStop:
            return .deferredForRecording
        case .waitForReauthentication:
            return .waitingForReauthentication
        case let .backoff(until):
            return .backingOff(until)
        case .run:
            return await run(now: now)
        }
    }

    /// Manual "Sync now": skips the hourly interval and any backoff window,
    /// but still refuses while re-login is required and never runs twice
    /// concurrently (AC14).
    func syncNow(now: Date = .now) async -> ExternalSyncRunStatus {
        guard !statePersistenceFailed else { return .statePersistenceFailed }
        guard state.authState == .ready else { return .waitingForReauthentication }
        return await run(now: now)
    }

    @discardableResult
    func didCompleteInteractiveLogin(at now: Date = .now) -> Bool {
        state = scheduler.applyingInteractiveLogin(to: state)
        return persist()
    }

    private func run(now: Date) async -> ExternalSyncRunStatus {
        guard !isRunning else { return .alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        // First run starts 7 days back; a checkpoint older than the cap is
        // clamped so a long-disabled provider catches up at most 7 days
        // (D-10, D-17; widened from 4 to 7 days by user decision 2026-07-17).
        let windowStart = now.addingTimeInterval(-Self.catchUpWindow)
        let since = max(syncedThrough ?? windowStart, windowStart)

        let listed: [ExternalRecording]
        do {
            listed = try await provider.listRecordings(since: since)
        } catch let error as ExternalSyncProviderError {
            switch error {
            case .needsLogin:
                state = scheduler.applying(.authenticationExpired, to: state, at: now)
                return persist() ? .authenticationExpired : .statePersistenceFailed
            case .notInstalled:
                return .notInstalled
            case .transientFailure:
                state = scheduler.applying(.transientFailure, to: state, at: now)
                return persist() ? .transientFailure : .statePersistenceFailed
            }
        } catch {
            state = scheduler.applying(.transientFailure, to: state, at: now)
            return persist() ? .transientFailure : .statePersistenceFailed
        }

        var imported = 0
        var retryableFailures = 0
        // Oldest first: the watermark only advances across an unbroken run of
        // successes, so a failed item keeps the checkpoint behind it and is
        // retried on the next sync (AC11).
        var watermarkBlocked = false
        for recording in listed.filter({ $0.startedAt >= since }).sorted(by: { $0.startedAt < $1.startedAt }) {
            guard importIndex.needsImport(remoteID: recording.remoteID) else {
                advanceWatermark(to: recording.startedAt, blocked: watermarkBlocked)
                continue
            }
            do {
                try await downloadAndImport(recording)
                importIndex.recordSuccess(remoteID: recording.remoteID, at: now)
                imported += 1
                advanceWatermark(to: recording.startedAt, blocked: watermarkBlocked)
            } catch let error as ExternalSyncProviderError where error == .needsLogin {
                importIndex.recordFailure(remoteID: recording.remoteID, code: "external_sync_needs_login")
                state = scheduler.applying(.authenticationExpired, to: state, at: now)
                return persist() ? .authenticationExpired : .statePersistenceFailed
            } catch {
                importIndex.recordFailure(remoteID: recording.remoteID, code: "external_sync_import_failed")
                retryableFailures += 1
                watermarkBlocked = true
            }
            guard persist() else { return .statePersistenceFailed }
        }

        state = scheduler.applying(.success, to: state, at: now)
        return persist() ? .completed(imported: imported, retryableFailures: retryableFailures) : .statePersistenceFailed
    }

    private func advanceWatermark(to startedAt: Date, blocked: Bool) {
        guard !blocked else { return }
        syncedThrough = max(syncedThrough ?? .distantPast, startedAt)
    }

    private func downloadAndImport(_ recording: ExternalRecording) async throws {
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent("damso-external-sync", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporary) }
        let audioFile = try await provider.downloadAudio(remoteID: recording.remoteID, into: temporary)
        try await importSink(recording, audioFile)
    }

    private func persist() -> Bool {
        guard let checkpointStore else { return true }
        do {
            try checkpointStore.save(ExternalSyncCheckpoint(
                schedulerState: state,
                importIndex: importIndex,
                syncedThrough: syncedThrough
            ))
            return true
        } catch {
            statePersistenceFailed = true
            return false
        }
    }
}
