import Foundation
import Testing
@testable import Damso

/// Regression coverage for the 5-minute cutoff (R4): the boundary decides
/// pipeline versus discard confirmation, [중지] applies the same rule with no
/// grace, no-response auto-discard is irreversible by contract, and discard
/// removes the recording from the meeting log while keep processes it.

private let chromeSource = DetectedMeetingSource(app: .chrome, service: .meet, titleHint: "Chrome · 스탠드업", tabID: "7")
private let epoch = Date(timeIntervalSince1970: 2_000_000)

private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

private func recordingMachine() -> MeetingSessionStateMachine {
    var machine = MeetingSessionStateMachine()
    _ = machine.observe(sources: [chromeSource], at: at(0))
    _ = machine.approveRecording(at: at(0))
    return machine
}

struct RecordingCutoffBoundaryTests {
    @Test
    func stopJustUnderCutoffAsksBeforeDiscarding() {
        var machine = recordingMachine()
        let effects = machine.stopPressed(at: at(299.9))
        #expect(effects.count == 1)
        guard case .shortRecordingConfirm = machine.state else {
            Issue.record("expected discard confirmation under the cutoff")
            return
        }
    }

    @Test
    func stopAtCutoffProcessesImmediately() {
        var machine = recordingMachine()
        let effects = machine.stopPressed(at: at(300))
        #expect(effects.contains { if case .processRecording = $0 { true } else { false } })
        #expect(machine.state == .idle)
    }

    @Test
    func graceEndedShortMeetingAlsoGetsTheConfirmation() {
        var machine = recordingMachine()
        // Mic ends at 2min; grace expires 60s later: 2min of recording.
        _ = machine.observe(sources: [], at: at(120))
        _ = machine.observe(sources: [], at: at(181))
        guard case .shortRecordingConfirm(_, let duration, _) = machine.state else {
            Issue.record("expected confirmation after grace on a short recording")
            return
        }
        #expect(duration == 181)
    }

    @Test
    func noResponseAutoDiscardsAfterTheDefaultTimeout() {
        var machine = recordingMachine()
        _ = machine.stopPressed(at: at(100))
        // One second before the deadline nothing happens.
        #expect(machine.observe(sources: [], at: at(100 + 299)).isEmpty)
        let effects = machine.observe(sources: [], at: at(100 + 300))
        guard case .discardRecording = effects.first else {
            Issue.record("expected auto discard at the deadline")
            return
        }
    }
}

// MARK: - Workspace integration: discard removes, keep processes

@MainActor
private final class CutoffFakeCapture: RecordingCapture {
    private var files: CapturedAudioFiles?

    func permissionState() async -> RecordingPermissionState { .ready }

    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles {
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        let microphone = recordingDirectory.appendingPathComponent("microphone.caf")
        let systemAudio = recordingDirectory.appendingPathComponent("system-audio.m4a")
        try Data("audio".utf8).write(to: microphone)
        try Data("system".utf8).write(to: systemAudio)
        let captured = CapturedAudioFiles(microphone: microphone, systemAudio: systemAudio)
        files = captured
        return captured
    }

    func stop() async throws -> CapturedAudioFiles {
        guard let files else { throw LocalRecordingError.notRecording }
        return files
    }
}

private final class CutoffFakeBackend: LocalProcessingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _phaseOneCount = 0
    var phaseOneCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _phaseOneCount
    }

    func runPhaseOne(_ request: LocalProcessingRequest) throws -> LocalProcessingResult {
        lock.lock()
        _phaseOneCount += 1
        lock.unlock()
        return LocalProcessingResult(ok: true, stage: "speaker_review", speakerCount: 0)
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
private func makeCutoffWorkspace() -> (MeetingWorkspaceController, CutoffFakeBackend, MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    let backend = CutoffFakeBackend()
    let controller = MeetingWorkspaceController(store: store, capture: CutoffFakeCapture(), backend: backend)
    return (controller, backend, store, root)
}

struct RecordingCutoffWorkspaceTests {
    @Test @MainActor
    func discardedShortRecordingNeverAppearsInTheMeetingLog() async throws {
        let (controller, backend, store, root) = makeCutoffWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await controller.detectionStartRecording())
        #expect(controller.isRecording)
        let directory = try #require(controller.activeRecordingDirectory())
        #expect(FileManager.default.fileExists(atPath: directory.path))

        #expect(await controller.detectionStopRecording())
        controller.detectionDiscardStoppedRecording()

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(try store.list().isEmpty)
        #expect(controller.records.isEmpty)
        #expect(backend.phaseOneCount == 0)
    }

    @Test @MainActor
    func keptShortRecordingRunsTheNormalPipeline() async throws {
        let (controller, backend, store, root) = makeCutoffWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(await controller.detectionStartRecording())
        #expect(await controller.detectionStopRecording())
        controller.detectionProcessStoppedRecording()

        // The pipeline task runs asynchronously; wait for the fake backend.
        for _ in 0..<100 where backend.phaseOneCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(backend.phaseOneCount == 1)
        #expect(try store.list().count == 1)
    }

    @Test @MainActor
    func failedRecordingStartReportsFalseSoTheSessionCanFallBack() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root, minimumFreeBytes: 0)

        @MainActor
        final class DeniedCapture: RecordingCapture {
            func permissionState() async -> RecordingPermissionState { .microphoneDenied }
            func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles { fatalError("unused") }
            func stop() async throws -> CapturedAudioFiles { fatalError("unused") }
        }

        let controller = MeetingWorkspaceController(store: store, capture: DeniedCapture(), backend: CutoffFakeBackend())
        #expect(await controller.detectionStartRecording() == false)
        #expect(!controller.isRecording)
    }
}
