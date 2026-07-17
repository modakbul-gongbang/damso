import AVFoundation
import Foundation
import Testing
@testable import Damso

// MARK: Fakes

private struct SinkFailure: Error {}

private final class FakeSyncProvider: ExternalSyncProvider, @unchecked Sendable {
    let id = "fakeprov"
    let displayName = "Fake Service"

    private let lock = NSLock()
    private var _account: ExternalSyncAccountState = .connected
    private var _recordings: [ExternalRecording] = []
    private var _listError: ExternalSyncProviderError?
    private var _listSinceCalls: [Date] = []
    private var _audioPayload: Data = Data("not-audio".utf8)
    var listDelayNanoseconds: UInt64 = 0

    var account: ExternalSyncAccountState {
        get { lock.withLock { _account } }
        set { lock.withLock { _account = newValue } }
    }

    var recordings: [ExternalRecording] {
        get { lock.withLock { _recordings } }
        set { lock.withLock { _recordings = newValue } }
    }

    var listError: ExternalSyncProviderError? {
        get { lock.withLock { _listError } }
        set { lock.withLock { _listError = newValue } }
    }

    var listSinceCalls: [Date] { lock.withLock { _listSinceCalls } }

    var audioPayload: Data {
        get { lock.withLock { _audioPayload } }
        set { lock.withLock { _audioPayload = newValue } }
    }

    func accountState() async -> ExternalSyncAccountState { account }
    func beginLogin() async throws {}
    func logout() async throws {}

    func listRecordings(since: Date) async throws -> [ExternalRecording] {
        lock.withLock { _listSinceCalls.append(since) }
        if listDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: listDelayNanoseconds)
        }
        if let error = listError { throw error }
        return recordings.filter { $0.startedAt >= since }
    }

    func downloadAudio(remoteID: String, into directory: URL) async throws -> URL {
        let destination = directory.appendingPathComponent("recording.caf")
        try audioPayload.write(to: destination)
        return destination
    }
}

/// Records every import the engine hands over; configurable per-item failure
/// stands in for a download that fails validation.
private final class ImportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _imported: [String] = []
    private var _failing: Set<String> = []

    var imported: [String] { lock.withLock { _imported } }

    func fail(_ remoteIDs: String...) {
        lock.withLock { _failing.formUnion(remoteIDs) }
    }

    func heal(_ remoteID: String) {
        lock.withLock { _ = _failing.remove(remoteID) }
    }

    var sink: ExternalSyncEngine.ImportSink {
        { [self] recording, _ in
            let shouldFail = lock.withLock { _failing.contains(recording.remoteID) }
            if shouldFail { throw SinkFailure() }
            lock.withLock { _imported.append(recording.remoteID) }
        }
    }
}

private func makeCheckpointStore() -> (ExternalSyncCheckpointStore, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ExternalSyncCheckpointStore(fileURL: directory.appendingPathComponent("fakeprov.json"))
    return (store, directory)
}

private let day: TimeInterval = 24 * 60 * 60

// MARK: Window and dedup (AC5)

@Test
func initialSyncImportsOnlyTheLastSevenDaysAndNeverDuplicates() async throws {
    let (checkpoints, directory) = makeCheckpointStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let provider = FakeSyncProvider()
    provider.recordings = [
        ExternalRecording(remoteID: "too-old", startedAt: now.addingTimeInterval(-8 * day)),
        ExternalRecording(remoteID: "recent-1", startedAt: now.addingTimeInterval(-2 * day)),
        ExternalRecording(remoteID: "recent-2", startedAt: now.addingTimeInterval(-1 * 60 * 60)),
    ]
    let recorder = ImportRecorder()
    let engine = ExternalSyncEngine(provider: provider, checkpointStore: checkpoints, importSink: recorder.sink)

    let first = await engine.syncNow(now: now)
    #expect(first == .completed(imported: 2, retryableFailures: 0))
    #expect(recorder.imported == ["recent-1", "recent-2"])
    #expect(provider.listSinceCalls.first == now.addingTimeInterval(-7 * day))

    // A relaunch reloads the checkpoint: nothing is imported twice and the
    // listing window starts at the watermark, not 7 days back.
    let relaunched = ExternalSyncEngine(provider: provider, checkpointStore: checkpoints, importSink: recorder.sink)
    let second = await relaunched.syncNow(now: now.addingTimeInterval(60 * 60))
    #expect(second == .completed(imported: 0, retryableFailures: 0))
    #expect(recorder.imported == ["recent-1", "recent-2"])
    #expect(provider.listSinceCalls.last == now.addingTimeInterval(-1 * 60 * 60))
}

@Test
func catchUpAfterReenableIsCappedAtSevenDays() async throws {
    let (checkpoints, directory) = makeCheckpointStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try checkpoints.save(ExternalSyncCheckpoint(
        schedulerState: .initial,
        importIndex: SyncImportIndex(),
        syncedThrough: now.addingTimeInterval(-20 * day)
    ))
    let provider = FakeSyncProvider()
    let engine = ExternalSyncEngine(provider: provider, checkpointStore: checkpoints, importSink: ImportRecorder().sink)

    _ = await engine.syncNow(now: now)
    #expect(provider.listSinceCalls == [now.addingTimeInterval(-7 * day)])
}

// MARK: Failure recovery and watermark (AC10, AC11)

@Test
func failedItemHoldsTheWatermarkAndIsRetriedNextSync() async throws {
    let (checkpoints, directory) = makeCheckpointStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let first = now.addingTimeInterval(-3 * day)
    let failedAt = now.addingTimeInterval(-2 * day)
    let provider = FakeSyncProvider()
    provider.recordings = [
        ExternalRecording(remoteID: "ok-1", startedAt: first),
        ExternalRecording(remoteID: "flaky", startedAt: failedAt),
        ExternalRecording(remoteID: "ok-2", startedAt: now.addingTimeInterval(-1 * day)),
    ]
    let recorder = ImportRecorder()
    recorder.fail("flaky")
    let engine = ExternalSyncEngine(provider: provider, checkpointStore: checkpoints, importSink: recorder.sink)

    let outcome = await engine.syncNow(now: now)
    #expect(outcome == .completed(imported: 2, retryableFailures: 1))
    #expect(recorder.imported == ["ok-1", "ok-2"])
    let persisted = try checkpoints.load()
    #expect(persisted?.syncedThrough == first)
    #expect(persisted?.importIndex.needsImport(remoteID: "flaky") == true)

    recorder.heal("flaky")
    let retry = await engine.syncNow(now: now.addingTimeInterval(60))
    #expect(retry == .completed(imported: 1, retryableFailures: 0))
    #expect(recorder.imported == ["ok-1", "ok-2", "flaky"])
    #expect(try checkpoints.load()?.syncedThrough == provider.recordings.last?.startedAt)
}

// MARK: Auth expiry pause and recovery (AC4, AC9)

@Test
func authExpiryPausesSyncUntilInteractiveLoginCompletes() async throws {
    let (checkpoints, directory) = makeCheckpointStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let provider = FakeSyncProvider()
    provider.listError = .needsLogin
    let engine = ExternalSyncEngine(provider: provider, checkpointStore: checkpoints, importSink: ImportRecorder().sink)

    #expect(await engine.syncNow(now: now) == .authenticationExpired)
    #expect(await engine.poll(now: now.addingTimeInterval(60), recordingIsActive: false) == .waitingForReauthentication)
    #expect(await engine.syncNow(now: now.addingTimeInterval(120)) == .waitingForReauthentication)

    provider.listError = nil
    await engine.didCompleteInteractiveLogin(at: now.addingTimeInterval(180))
    #expect(await engine.syncNow(now: now.addingTimeInterval(200)) == .completed(imported: 0, retryableFailures: 0))
}

@Test
func transientFailureBacksOffInsteadOfHammering() async throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let provider = FakeSyncProvider()
    provider.listError = .transientFailure("network")
    let engine = ExternalSyncEngine(provider: provider, importSink: ImportRecorder().sink)

    #expect(await engine.poll(now: now, recordingIsActive: false) == .transientFailure)
    let next = await engine.poll(now: now.addingTimeInterval(1), recordingIsActive: false)
    guard case .backingOff = next else {
        Issue.record("Expected a backoff window after a transient failure, got \(next)")
        return
    }
}

// MARK: Serialization (AC14)

@Test
func concurrentRunsAreSerializedPerProvider() async throws {
    let (checkpoints, directory) = makeCheckpointStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let provider = FakeSyncProvider()
    provider.listDelayNanoseconds = 500_000_000
    provider.recordings = [ExternalRecording(remoteID: "single", startedAt: now.addingTimeInterval(-60))]
    let recorder = ImportRecorder()
    let engine = ExternalSyncEngine(provider: provider, checkpointStore: checkpoints, importSink: recorder.sink)

    let firstRun = Task { await engine.syncNow(now: now) }
    try await Task.sleep(nanoseconds: 100_000_000)
    let overlapping = await engine.syncNow(now: now)
    #expect(overlapping == .alreadyRunning)

    let first = await firstRun.value
    #expect(first == .completed(imported: 1, retryableFailures: 0))
    #expect(recorder.imported == ["single"])
    #expect(try checkpoints.load()?.syncedThrough == provider.recordings.first?.startedAt)
}

// MARK: Store-level import contract (AC10)

@Test
func commitImportedMovesAudioAtomicallyAndRejectsDuplicates() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    let staged = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).caf")
    try Data("audio-bytes".utf8).write(to: staged)

    var record = try store.createRecord(MeetingDraft(stem: "fakeprov-abc", source: .plaud, title: ""))
    record.originalAudioFile = staged.lastPathComponent
    try store.commitImported(record, movingAudioFrom: staged)

    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: "fakeprov-abc")
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting.json").path))
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(staged.lastPathComponent).path))
    #expect(!FileManager.default.fileExists(atPath: staged.path))

    let again = FileManager.default.temporaryDirectory.appendingPathComponent("import-again.caf")
    try Data("audio-bytes".utf8).write(to: again)
    var duplicate = record
    duplicate.originalAudioFile = again.lastPathComponent
    #expect(throws: MeetingStoreError.duplicateMeeting) {
        try store.commitImported(duplicate, movingAudioFrom: again)
    }
    try? FileManager.default.removeItem(at: again)
}

// MARK: End-to-end import path (AC6, AC10, D-16)

private final class SyncFakeBackend: LocalProcessingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _phaseOneRequests: [LocalProcessingRequest] = []

    var phaseOneRequests: [LocalProcessingRequest] { lock.withLock { _phaseOneRequests } }

    func runPhaseOne(_ request: LocalProcessingRequest) throws -> LocalProcessingResult {
        lock.withLock { _phaseOneRequests.append(request) }
        return LocalProcessingResult(ok: true, stage: "complete", speakerCount: 1)
    }

    func applyResolutions(_ request: LocalResolutionProcessingRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func appendPersonNote(_ request: LocalPersonNoteRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func refreshCandidates(_ request: LocalRefreshCandidatesRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func setPersonEmail(_ request: LocalPersonEmailRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func removePersonAlias(_ request: LocalRemovePersonAliasRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func runSummary(_ request: LocalSummaryRequest) throws -> LocalSummaryResult { fatalError("unused") }
    func suggestSpeakers(_ request: LocalSpeakerHintsRequest) throws -> LocalSpeakerHintsResult { fatalError("unused") }
    func cleanTranscript(_ request: LocalTranscriptCleanupRequest) throws -> LocalTranscriptCleanupResult { fatalError("unused") }
    func rebuildIndex(storeRoot: String) throws -> LocalIndexResult { LocalIndexResult(ok: true, meetings: 0) }
}

@MainActor
private final class SyncNoopCapture: RecordingCapture {
    func permissionState() async -> RecordingPermissionState { .ready }
    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles { fatalError("unused") }
    func stop() async throws -> CapturedAudioFiles { fatalError("unused") }
}

private func writePlayableAudio(to url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_200)!
    buffer.frameLength = 3_200
    try file.write(from: buffer)
}

@Test @MainActor
func importedRecordingBecomesAPlaudSourcedMeetingAndStartsThePipeline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    try store.bootstrap()
    let backend = SyncFakeBackend()
    let workspace = MeetingWorkspaceController(store: store, capture: SyncNoopCapture(), backend: backend)

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let provider = FakeSyncProvider()
    let audioFixture = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString).caf")
    try writePlayableAudio(to: audioFixture)
    provider.audioPayload = try Data(contentsOf: audioFixture)
    try? FileManager.default.removeItem(at: audioFixture)
    provider.recordings = [ExternalRecording(remoteID: "wrist001", title: nil, startedAt: now.addingTimeInterval(-60 * 60))]

    let sink = ExternalSyncController.makeImportSink(providerID: provider.id, storeRoot: root, workspace: workspace)
    let engine = ExternalSyncEngine(provider: provider, importSink: sink)

    let outcome = await engine.syncNow(now: now)
    #expect(outcome == .completed(imported: 1, retryableFailures: 0))

    let record = try store.load(stem: "fakeprov-wrist001")
    #expect(record.source == .plaud)
    #expect(record.title.isEmpty)
    #expect(record.durationSeconds ?? 0 > 0)
    #expect(record.originalAudioFile == "recording.caf")

    // The local pipeline starts automatically for the imported meeting.
    for _ in 0..<50 where backend.phaseOneRequests.isEmpty {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(backend.phaseOneRequests.count == 1)
}

/// While its turn is actually running, an imported meeting shows the live
/// "Transcribing" stage instead of a stale queued badge; the badge lands on
/// speaker review when the subprocess finishes.
@Test @MainActor
func importedProcessingShowsTranscribingWhileRunning() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    var record = try store.createRecord(MeetingDraft(stem: "fakeprov-live", source: .plaud, title: ""))
    record.stage = .queued
    record.originalAudioFile = "recording.caf"
    try store.commit(record, artifacts: ["recording.caf": Data("audio".utf8)])

    final class GatedBackend: LocalProcessingBackend, @unchecked Sendable {
        let gate = DispatchSemaphore(value: 0)
        func runPhaseOne(_ request: LocalProcessingRequest) throws -> LocalProcessingResult {
            gate.wait()
            return LocalProcessingResult(ok: true, stage: "complete", speakerCount: 1)
        }

        func applyResolutions(_ request: LocalResolutionProcessingRequest) throws -> LocalProcessingResult { fatalError("unused") }
        func appendPersonNote(_ request: LocalPersonNoteRequest) throws -> LocalProcessingResult { fatalError("unused") }
        func refreshCandidates(_ request: LocalRefreshCandidatesRequest) throws -> LocalProcessingResult { fatalError("unused") }
        func setPersonEmail(_ request: LocalPersonEmailRequest) throws -> LocalProcessingResult { fatalError("unused") }
        func removePersonAlias(_ request: LocalRemovePersonAliasRequest) throws -> LocalProcessingResult { fatalError("unused") }
        func runSummary(_ request: LocalSummaryRequest) throws -> LocalSummaryResult { fatalError("unused") }
        func suggestSpeakers(_ request: LocalSpeakerHintsRequest) throws -> LocalSpeakerHintsResult { fatalError("unused") }
        func cleanTranscript(_ request: LocalTranscriptCleanupRequest) throws -> LocalTranscriptCleanupResult { fatalError("unused") }
        func rebuildIndex(storeRoot: String) throws -> LocalIndexResult { LocalIndexResult(ok: true, meetings: 0) }
    }
    let backend = GatedBackend()
    let workspace = MeetingWorkspaceController(store: store, capture: SyncNoopCapture(), backend: backend)
    workspace.refreshLibrary()
    workspace.processImportedMeeting(stem: "fakeprov-live")

    for _ in 0..<50 where (try? store.load(stem: "fakeprov-live"))?.stage != .transcribing {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(try store.load(stem: "fakeprov-live").stage == .transcribing)

    backend.gate.signal()
    for _ in 0..<50 where (try? store.load(stem: "fakeprov-live"))?.stage != .speakerReview {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(try store.load(stem: "fakeprov-live").stage == .speakerReview)
}

/// A quit mid-transcription leaves an imported meeting in the queued stage;
/// the launch-time resume restarts it so external sync's automatic pipeline
/// promise survives restarts (R6).
@Test @MainActor
func interruptedImportedProcessingResumesOnLaunch() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    var record = try store.createRecord(MeetingDraft(stem: "fakeprov-interrupted", source: .plaud, title: ""))
    record.stage = .queued
    record.originalAudioFile = "recording.caf"
    try store.commit(record, artifacts: ["recording.caf": Data("audio".utf8)])

    let backend = SyncFakeBackend()
    let workspace = MeetingWorkspaceController(store: store, capture: SyncNoopCapture(), backend: backend)
    workspace.refreshLibrary()
    workspace.resumeInterruptedImportedProcessing()

    for _ in 0..<50 where backend.phaseOneRequests.isEmpty {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(backend.phaseOneRequests.count == 1)
    for _ in 0..<50 where (try? store.load(stem: "fakeprov-interrupted"))?.stage != .speakerReview {
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    #expect(try store.load(stem: "fakeprov-interrupted").stage == .speakerReview)
}

@Test @MainActor
func unplayableDownloadIsDiscardedAndNeverAppearsInTheMeetingList() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    try store.bootstrap()
    let workspace = MeetingWorkspaceController(store: store, capture: SyncNoopCapture(), backend: SyncFakeBackend())

    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let provider = FakeSyncProvider()
    provider.audioPayload = Data("definitely-not-audio".utf8)
    provider.recordings = [ExternalRecording(remoteID: "corrupt01", startedAt: now.addingTimeInterval(-60 * 60))]

    let sink = ExternalSyncController.makeImportSink(providerID: provider.id, storeRoot: root, workspace: workspace)
    let engine = ExternalSyncEngine(provider: provider, importSink: sink)

    let outcome = await engine.syncNow(now: now)
    #expect(outcome == .completed(imported: 0, retryableFailures: 1))
    #expect(try store.list().isEmpty)
    let recordings = CanonicalStoreLayout(root: root).recordings
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: recordings.path)) ?? []
    #expect(leftovers.isEmpty)
}
