import Foundation
import Testing
@testable import Damso

@Test
func queuesHeavyWorkSeriallyAndResumesAtItsCheckpoint() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DurableJobQueue(fileURL: directory.appendingPathComponent("queue.json"))
    let transcription = try queue.enqueue(meetingStem: "fixture-a", kind: .transcription)
    _ = try queue.enqueue(meetingStem: "fixture-b", kind: .plaudSync)

    #expect(try queue.nextRunnable(recordingIsActive: true) == nil)
    let running = try #require(try queue.nextRunnable(recordingIsActive: false))
    #expect(running.id == transcription.id)
    #expect(throws: DurableJobQueueError.self) {
        _ = try queue.nextRunnable(recordingIsActive: false)
    }

    try queue.checkpoint(running.id, stage: .transcribing, artifactChecksum: "fixture-checksum")
    let recovered = try queue.recoverAfterUnexpectedExit()
    #expect(recovered.first?.state == .queued)
    #expect(recovered.first?.checkpoint?.stage == .transcribing)
}

@Test
func interruptedExternalSummaryRequiresExplicitRetry() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DurableJobQueue(fileURL: directory.appendingPathComponent("queue.json"))
    let summary = try queue.enqueue(meetingStem: "fixture-a", kind: .summary)
    _ = try queue.nextRunnable(recordingIsActive: false)

    let recovered = try queue.recoverAfterUnexpectedExit()
    #expect(recovered.first?.id == summary.id)
    #expect(recovered.first?.state == .awaitingExplicitRetry)
    #expect(recovered.first?.lastErrorCode == "external_cli_completion_unknown")
    try queue.retry(summary.id)
    #expect(queue.all().first?.state == .queued)
}

@Test
func failedWorkRecordsAStableCodeAndCanBeExplicitlyRetried() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let queue = try DurableJobQueue(fileURL: directory.appendingPathComponent("queue.json"))
    let job = try queue.enqueue(meetingStem: "fixture", kind: .transcription)
    _ = try queue.nextRunnable(recordingIsActive: false)

    try queue.fail(job.id, errorCode: "local_processing_operation_failed")
    #expect(queue.all().first?.state == .failed)
    #expect(queue.all().first?.lastErrorCode == "local_processing_operation_failed")
    try queue.retry(job.id)
    #expect(queue.all().first?.state == .queued)
}
