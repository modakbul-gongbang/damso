import Foundation

enum WorkExecutionOutcome: Sendable {
    case complete
    case checkpoint(stage: ProcessingStage, artifactChecksum: String?)
}

enum WorkRunResult: Equatable, Sendable {
    case idle
    case deferredForRecording
    case busy
    case completed(UUID)
    case failed(UUID)
}

/// A single actor owns all heavy processing transitions.
///
/// Capture, menus, and SwiftUI state remain on the main actor while this actor
/// waits for a local subprocess or filesystem operation. A second heavy job
/// cannot start while one job has the queue's running checkpoint.
actor ProcessingWorkCoordinator {
    private let queue: DurableJobQueue

    init(queue: DurableJobQueue) {
        self.queue = queue
    }

    @discardableResult
    func enqueue(meetingStem: String, kind: JobKind) throws -> DurableJob {
        try queue.enqueue(meetingStem: meetingStem, kind: kind)
    }

    func allJobs() -> [DurableJob] {
        queue.all()
    }

    func processNext(
        recordingIsActive: Bool,
        operation: @Sendable (DurableJob) async throws -> WorkExecutionOutcome
    ) async -> WorkRunResult {
        guard !recordingIsActive else { return .deferredForRecording }
        let job: DurableJob
        do {
            guard let next = try queue.nextRunnable(recordingIsActive: false) else { return .idle }
            job = next
        } catch DurableJobQueueError.alreadyRunning {
            return .busy
        } catch {
            return .idle
        }

        do {
            let outcome = try await operation(job)
            if case let .checkpoint(stage, checksum) = outcome {
                try queue.checkpoint(job.id, stage: stage, artifactChecksum: checksum)
            }
            try queue.finish(job.id)
            return .completed(job.id)
        } catch {
            try? queue.fail(job.id, errorCode: "local_processing_operation_failed")
            return .failed(job.id)
        }
    }
}
