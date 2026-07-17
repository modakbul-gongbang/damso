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
