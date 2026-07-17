import Foundation
import Testing
@testable import Damso

@Test
func schedulerUsesSingleCatchUpAndDefersToRecording() {
    let scheduler = SyncScheduler(interval: 60, initialBackoff: 5, maximumBackoff: 20)
    let now = Date(timeIntervalSince1970: 1_000)
    let state = SyncSchedulerState(lastSuccessfulRun: now.addingTimeInterval(-180), nextAllowedRun: nil, consecutiveFailures: 0, authState: .ready)

    #expect(scheduler.decision(for: state, now: now, recordingIsActive: true) == .waitForRecordingToStop)
    #expect(scheduler.decision(for: state, now: now, recordingIsActive: false) == .run(catchUp: true))
}

@Test
func schedulerBacksOffWithACapAndStopsOnAuthenticationExpiry() {
    let scheduler = SyncScheduler(interval: 60, initialBackoff: 5, maximumBackoff: 20, jitter: { _ in 3 })
    let now = Date(timeIntervalSince1970: 1_000)
    var state = SyncSchedulerState.initial
    state = scheduler.applying(.transientFailure, to: state, at: now)
    #expect(state.nextAllowedRun == now.addingTimeInterval(8))
    state = scheduler.applying(.transientFailure, to: state, at: now)
    #expect(state.nextAllowedRun == now.addingTimeInterval(13))
    state = scheduler.applying(.transientFailure, to: state, at: now)
    #expect(state.nextAllowedRun == now.addingTimeInterval(20))

    state = scheduler.applying(.authenticationExpired, to: state, at: now)
    #expect(scheduler.decision(for: state, now: now.addingTimeInterval(500), recordingIsActive: false) == .waitForReauthentication)
    #expect(scheduler.applyingInteractiveLogin(to: state).authState == .ready)
}

@Test
func fileImportIndexKeepsFailedFilesRetryableWithoutRedownloadingSuccesses() {
    var index = SyncImportIndex()
    index.recordSuccess(remoteID: "already-imported", at: Date(timeIntervalSince1970: 1))
    index.recordFailure(remoteID: "retryable", code: "network")
    #expect(!index.needsImport(remoteID: "already-imported"))
    #expect(index.needsImport(remoteID: "retryable"))
}

@Test
func schedulerRunsOneCatchUpAfterClockRecoveryAndDoesNotRepeatIt() {
    let scheduler = SyncScheduler(interval: 60)
    let beforeCorrection = Date(timeIntervalSince1970: 1_000)
    let state = SyncSchedulerState(lastSuccessfulRun: beforeCorrection.addingTimeInterval(120), nextAllowedRun: nil, consecutiveFailures: 0, authState: .ready)
    #expect(scheduler.decision(for: state, now: beforeCorrection, recordingIsActive: false) == .idle)

    let correctedClock = beforeCorrection.addingTimeInterval(240)
    #expect(scheduler.decision(for: state, now: correctedClock, recordingIsActive: false) == .run(catchUp: true))
    let completed = scheduler.applying(.success, to: state, at: correctedClock)
    #expect(scheduler.decision(for: completed, now: correctedClock, recordingIsActive: false) == .idle)
}
