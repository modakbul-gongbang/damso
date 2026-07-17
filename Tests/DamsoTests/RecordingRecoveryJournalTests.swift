import Foundation
import Testing
@testable import Damso

@MainActor
private final class JournalCapture: RecordingCapture {
    let files: CapturedAudioFiles

    init(files: CapturedAudioFiles) {
        self.files = files
    }

    func permissionState() async -> RecordingPermissionState {
        .ready
    }

    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles {
        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        try Data("microphone-fixture".utf8).write(to: files.microphone)
        try Data("system-fixture".utf8).write(to: files.systemAudio)
        return files
    }

    func stop() async throws -> CapturedAudioFiles {
        files
    }
}

@Test
func interruptedRecordingKeepsOnlyLastVerifiedAudioAndNeverClaimsCompletion() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let files = CapturedAudioFiles(
        microphone: directory.appendingPathComponent("microphone.caf"),
        systemAudio: directory.appendingPathComponent("system-audio.m4a")
    )
    try Data("microphone-fixture".utf8).write(to: files.microphone)
    try Data("system-fixture".utf8).write(to: files.systemAudio)

    let active = RecordingRecoveryJournal(recordingDirectory: directory)
    try active.begin(files: files)
    let checkpoint = try active.checkpoint(files: files)
    #expect(checkpoint.status == .capturing)
    #expect(checkpoint.files.map(\.relativePath) == ["microphone.caf", "system-audio.m4a"])

    let relaunched = RecordingRecoveryJournal(recordingDirectory: directory)
    let recovered = try #require(try relaunched.recoverAfterUnexpectedExit())
    #expect(recovered.status == .interrupted)
    #expect(recovered.failureCode == "recording_interrupted")
    #expect(recovered.files == checkpoint.files)
}

@Test
func recordingRecoveryRefusesAudioOutsideTheCanonicalRecordDirectory() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = CapturedAudioFiles(
        microphone: directory.appendingPathComponent("microphone.caf"),
        systemAudio: FileManager.default.temporaryDirectory.appendingPathComponent("outside-system-audio.m4a")
    )
    let journal = RecordingRecoveryJournal(recordingDirectory: directory)

    #expect(throws: RecordingRecoveryError.self) {
        try journal.begin(files: files)
    }
    #expect(try journal.read() == nil)
}

@MainActor
@Test
func recordingControllerWritesRecoverableCheckpointsAroundCapture() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let files = CapturedAudioFiles(
        microphone: directory.appendingPathComponent("microphone.caf"),
        systemAudio: directory.appendingPathComponent("system-audio.m4a")
    )
    let journal = RecordingRecoveryJournal(recordingDirectory: directory)
    let session = RecordingSessionController(capture: JournalCapture(files: files), recoveryJournal: journal)

    _ = try await session.startNow(in: directory)
    #expect(try journal.read()?.status == .capturing)
    _ = try await session.stop()
    let stopped = try #require(try journal.read())
    #expect(stopped.status == .stopped)
    #expect(stopped.files.count == 2)
}
