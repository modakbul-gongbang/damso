import Foundation

/// Last known outcome of talking to the server daemon, updated by every
/// remote code path (`/v1/rpc`, changes sync, upload, on-demand file fetch)
/// as a side effect of doing their own work - never by a dedicated
/// health-check ping of its own, so this never adds HTTP round-trips beyond
/// the ones already happening (R9b). A plain lock-guarded singleton rather
/// than an `ObservableObject`: it is written from background tasks/detached
/// tasks all over Core, and `MeetingWorkspaceController` is the one place
/// that turns it into a `@Published` value for SwiftUI.
final class RemoteConnectivityTracker: @unchecked Sendable {
    enum Status: Equatable {
        case connected
        case disconnected
        /// The server rejected `X-Damso-Protocol-Version` - it is reachable,
        /// but its Damso build disagrees with this client's.
        case versionMismatch
    }

    static let shared = RemoteConnectivityTracker()

    private let lock = NSLock()
    private var _status: Status = .connected

    var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    func noteSuccess() {
        set(.connected)
    }

    /// Only `.transportFailed` means the server was actually unreachable;
    /// `.unauthorized`/`.notFound`/`.payloadTooLarge`/`.unprocessable`/
    /// `.backend`/`.invalidResponse` all mean a response came back, which is
    /// itself proof the server is there, so those count as connected too.
    /// `.requestEncoding`/`.remoteMisconfigured` are local/config issues
    /// unrelated to live reachability either way, so they leave the status
    /// alone instead of claiming either state on its behalf.
    func noteFailure(_ error: DamsoServerError) {
        switch error {
        case .remoteUpdateRequired:
            set(.versionMismatch)
        case .transportFailed:
            set(.disconnected)
        case .unauthorized, .notFound, .conflict, .payloadTooLarge, .unprocessable, .backend, .invalidResponse:
            set(.connected)
        case .requestEncoding, .remoteMisconfigured:
            break
        }
    }

    /// Upload/download paths that only ever report a plain success/fail
    /// boolean, not a typed error, so there is no protocol-error/backend-error
    /// distinction to preserve here.
    func noteTransferResult(succeeded: Bool) {
        set(succeeded ? .connected : .disconnected)
    }

    private func set(_ status: Status) {
        lock.lock()
        _status = status
        lock.unlock()
    }
}
