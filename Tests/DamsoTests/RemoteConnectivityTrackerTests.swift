import Testing
@testable import Damso

@Test
func trackerStartsConnectedAndNoteSuccessKeepsItConnected() {
    let tracker = RemoteConnectivityTracker()
    #expect(tracker.status == .connected)
    tracker.noteSuccess()
    #expect(tracker.status == .connected)
}

@Test
func versionMismatchIsReportedDistinctlyFromAPlainDisconnect() {
    let tracker = RemoteConnectivityTracker()
    tracker.noteFailure(.remoteUpdateRequired)
    #expect(tracker.status == .versionMismatch)
}

@Test
func transportAndLaunchFailuresBothMeanDisconnected() {
    let launchFailedTracker = RemoteConnectivityTracker()
    launchFailedTracker.noteFailure(.launchFailed)
    #expect(launchFailedTracker.status == .disconnected)

    let transportFailedTracker = RemoteConnectivityTracker()
    transportFailedTracker.noteFailure(.transportFailed(exitCode: 255))
    #expect(transportFailedTracker.status == .disconnected)
}

@Test
func aResponseThatCameBackAtAllCountsAsConnectedEvenWhenItIsAnErrorEnvelope() {
    // A protocol error, a backend error, an oversized body, or an undecodable
    // body all mean the mini answered - that is proof of reachability, not
    // evidence of a drop, so a stale "disconnected" status from an earlier
    // failure should clear rather than stick.
    for error in [
        DamsoServeError.protocolError(code: -32601, message: "unknown operation"),
        .backend(code: "invalid_local_processing_request", nextAction: "retry"),
        .oversizedResponse,
        .invalidResponse,
    ] as [DamsoServeError] {
        let tracker = RemoteConnectivityTracker()
        tracker.noteFailure(.launchFailed)
        #expect(tracker.status == .disconnected)
        tracker.noteFailure(error)
        #expect(tracker.status == .connected)
    }
}

@Test
func localOrConfigurationIssuesLeaveTheLastKnownStatusUntouched() {
    for error in [DamsoServeError.requestEncoding, .remoteMisconfigured] {
        let tracker = RemoteConnectivityTracker()
        tracker.noteFailure(.launchFailed)
        #expect(tracker.status == .disconnected)
        tracker.noteFailure(error)
        #expect(tracker.status == .disconnected)
    }
}

@Test
func transferResultReportsConnectedOrDisconnectedForRsyncBasedPaths() {
    let tracker = RemoteConnectivityTracker()
    tracker.noteTransferResult(succeeded: false)
    #expect(tracker.status == .disconnected)
    tracker.noteTransferResult(succeeded: true)
    #expect(tracker.status == .connected)
}
