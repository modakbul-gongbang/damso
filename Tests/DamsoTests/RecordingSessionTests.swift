import Foundation
import Testing
@testable import Damso

@MainActor
private final class FakeRecordingCapture: RecordingCapture {
    var permission: RecordingPermissionState
    var startCalls = 0
    var stopCalls = 0
    let files: CapturedAudioFiles

    init(permission: RecordingPermissionState, files: CapturedAudioFiles) {
        self.permission = permission
        self.files = files
    }

    func permissionState() async -> RecordingPermissionState {
        permission
    }

    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles {
        startCalls += 1
        return files
    }

    func stop() async throws -> CapturedAudioFiles {
        stopCalls += 1
        return files
    }
}

@MainActor
@Test
func captureStartsBeforeOptionalHintsAndKeepsHintsEditableAfterStop() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let files = CapturedAudioFiles(
        microphone: directory.appendingPathComponent("microphone.caf"),
        systemAudio: directory.appendingPathComponent("system-audio.m4a")
    )
    let capture = FakeRecordingCapture(permission: .ready, files: files)
    let session = RecordingSessionController(capture: capture)

    let started = try await session.startNow(in: directory)
    #expect(started == files)
    #expect(capture.startCalls == 1)
    #expect(session.hints == .empty)
    #expect(session.state == .recording(files))

    session.updateHints(MeetingHints(participants: ["Kim"], topic: "Synthetic", domainTerms: ["fixture"], numSpeakers: 2))
    #expect(session.hints.participants == ["Kim"])
    #expect(session.hints.topic == "Synthetic")

    let stopped = try await session.stop()
    #expect(stopped == files)
    #expect(capture.stopCalls == 1)
    #expect(session.state == .stopped(files))
    session.updateHints(MeetingHints(participants: ["Kim"], topic: "Revised", domainTerms: [], numSpeakers: nil))
    #expect(session.hints.topic == "Revised")
}

@MainActor
@Test
func deniedSystemAudioPermissionBlocksCaptureAndProvidesRecoveryAction() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let files = CapturedAudioFiles(
        microphone: directory.appendingPathComponent("microphone.caf"),
        systemAudio: directory.appendingPathComponent("system-audio.m4a")
    )
    let capture = FakeRecordingCapture(permission: .screenRecordingDenied, files: files)
    let session = RecordingSessionController(capture: capture)

    await #expect(throws: RecordingSessionError.self) {
        try await session.startNow(in: directory)
    }
    #expect(capture.startCalls == 0)
    #expect(session.state == .blocked(.screenRecordingDenied))
    #expect(session.recoveryAction?.contains("Screen Recording") == true)
}

@Test
func recordingSessionLegacyMeetingJSONDecodesWithoutNewAudioFields() throws {
    let record = MeetingRecord(
        stem: "legacy-audio-contract",
        source: .local,
        title: "Legacy",
        originalAudioFile: "microphone.caf",
        systemAudioFile: "system-audio.m4a",
        processedAudioFile: "combined-audio.m4a"
    )
    let encoder = JSONEncoder()
    DateCoding.configure(encoder)
    var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
    object.removeValue(forKey: "systemAudioFile")
    object.removeValue(forKey: "processedAudioFile")
    let legacy = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    DateCoding.configure(decoder)

    let decoded = try decoder.decode(MeetingRecord.self, from: legacy)

    #expect(decoded.originalAudioFile == "microphone.caf")
    #expect(decoded.systemAudioFile == nil)
    #expect(decoded.processedAudioFile == nil)
    #expect(decoded.schemaVersion == 1)
}

@Test @MainActor
func recordingSessionPlaybackPrefersCombinedAudioAndFallsBackToRawMicrophone() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    var record = try store.createRecord(MeetingDraft(stem: "playback-audio-contract", source: .local, title: "Synthetic"))
    record.originalAudioFile = "microphone.caf"
    record.systemAudioFile = "system-audio.m4a"
    record.processedAudioFile = "combined-audio.m4a"
    try store.commit(record, artifacts: [
        "microphone.caf": Data("mic".utf8),
        "system-audio.m4a": Data("system".utf8),
        "combined-audio.m4a": Data("combined".utf8),
    ])
    let controller = MeetingWorkspaceController(store: store, capture: FakeRecordingCapture(
        permission: .ready,
        files: CapturedAudioFiles(
            microphone: root.appendingPathComponent("unused-mic"),
            systemAudio: root.appendingPathComponent("unused-system")
        )
    ))

    #expect(controller.sourceAudioURL(for: record)?.lastPathComponent == "combined-audio.m4a")
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try FileManager.default.removeItem(at: directory.appendingPathComponent("combined-audio.m4a"))
    #expect(controller.sourceAudioURL(for: record)?.lastPathComponent == "microphone.caf")

    let outside = root.appendingPathComponent("outside.m4a")
    try Data("outside".utf8).write(to: outside)
    let linked = directory.appendingPathComponent("combined-audio.m4a")
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    #expect(controller.sourceAudioURL(for: record)?.lastPathComponent == "microphone.caf")

    try FileManager.default.removeItem(at: directory.appendingPathComponent("microphone.caf"))
    try FileManager.default.createSymbolicLink(
        at: directory.appendingPathComponent("microphone.caf"),
        withDestinationURL: outside
    )
    #expect(controller.sourceAudioURL(for: record) == nil)
}
