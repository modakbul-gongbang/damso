import Foundation
import Testing
@testable import Damso

private actor WorkGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

private func isCompleted(_ result: WorkRunResult) -> Bool {
    if case .completed = result { return true }
    return false
}

@Test
func processingWorkDefersDuringRecordingAndExecutesQueuedWorkOffTheUIActor() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: file) }
    let queue = try DurableJobQueue(fileURL: file)
    let coordinator = ProcessingWorkCoordinator(queue: queue)
    let job = try await coordinator.enqueue(meetingStem: "fixture", kind: .transcription)

    let deferred = await coordinator.processNext(recordingIsActive: true) { _ in
        Issue.record("A recording-active queue must not invoke heavy work.")
        return .complete
    }
    #expect(deferred == .deferredForRecording)
    let deferredJobs = await coordinator.allJobs()
    #expect(deferredJobs.first?.state == .queued)

    let result = await coordinator.processNext(recordingIsActive: false) { active in
        #expect(active.id == job.id)
        return .checkpoint(stage: .speakerReview, artifactChecksum: "fixture-checksum")
    }
    #expect(result == .completed(job.id))
    let finished = try #require((await coordinator.allJobs()).first)
    #expect(finished.state == .complete)
    #expect(finished.checkpoint?.stage == .speakerReview)
}

@Test
func processingWorkDoesNotStartASecondHeavyJobWhileTheFirstAwaitsItsOperation() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: file) }
    let queue = try DurableJobQueue(fileURL: file)
    let coordinator = ProcessingWorkCoordinator(queue: queue)
    _ = try await coordinator.enqueue(meetingStem: "first", kind: .transcription)
    _ = try await coordinator.enqueue(meetingStem: "second", kind: .speakerReview)
    let gate = WorkGate()

    let first = Task {
        await coordinator.processNext(recordingIsActive: false) { _ in
            await gate.wait()
            return .complete
        }
    }
    try await Task.sleep(for: .milliseconds(10))
    let second = await coordinator.processNext(recordingIsActive: false) { _ in
        Issue.record("A second heavy operation must not run while the first is active.")
        return .complete
    }
    #expect(second == .busy)

    await gate.open()
    let firstResult = await first.value
    #expect(isCompleted(firstResult))
    let jobs = await coordinator.allJobs()
    #expect(jobs.filter { $0.state == .complete }.count == 1)
    #expect(jobs.filter { $0.state == .queued }.count == 1)
}
