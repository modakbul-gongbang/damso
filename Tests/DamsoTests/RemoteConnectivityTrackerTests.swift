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
func transportFailureMeansDisconnected() {
    let tracker = RemoteConnectivityTracker()
    tracker.noteFailure(.transportFailed)
    #expect(tracker.status == .disconnected)
}

@Test
func aResponseThatCameBackAtAllCountsAsConnectedEvenWhenItIsAnErrorEnvelope() {
    // A 401, a 404, a backend error, a rejected upload, or an undecodable
    // body all mean the server answered - that is proof of reachability, not
    // evidence of a drop, so a stale "disconnected" status from an earlier
    // failure should clear rather than stick.
    for error in [
        DamsoServerError.unauthorized,
        .notFound,
        .conflict,
        .payloadTooLarge,
        .unprocessable(detail: "bad archive"),
        .backend(code: "invalid_local_processing_request", nextAction: "retry"),
        .invalidResponse,
    ] {
        let tracker = RemoteConnectivityTracker()
        tracker.noteFailure(.transportFailed)
        #expect(tracker.status == .disconnected)
        tracker.noteFailure(error)
        #expect(tracker.status == .connected)
    }
}

@Test
func localOrConfigurationIssuesLeaveTheLastKnownStatusUntouched() {
    for error in [DamsoServerError.requestEncoding, .remoteMisconfigured] {
        let tracker = RemoteConnectivityTracker()
        tracker.noteFailure(.transportFailed)
        #expect(tracker.status == .disconnected)
        tracker.noteFailure(error)
        #expect(tracker.status == .disconnected)
    }
}

@Test
func transferResultReportsConnectedOrDisconnectedForUploadDownloadPaths() {
    let tracker = RemoteConnectivityTracker()
    tracker.noteTransferResult(succeeded: false)
    #expect(tracker.status == .disconnected)
    tracker.noteTransferResult(succeeded: true)
    #expect(tracker.status == .connected)
}
