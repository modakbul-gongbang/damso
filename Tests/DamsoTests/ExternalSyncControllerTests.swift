import Foundation
import Testing
@testable import Damso

private final class SpyNotifier: UserNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _posts: [(title: String, body: String)] = []

    var posts: [(title: String, body: String)] { lock.withLock { _posts } }

    func post(title: String, body: String, userInfo: [String: String]) {
        lock.withLock { _posts.append((title, body)) }
    }
}

private final class ExpiringProvider: ExternalSyncProvider, @unchecked Sendable {
    let id = "fakeprov"
    let displayName = "Fake Service"

    func accountState() async -> ExternalSyncAccountState { .connected }
    func beginLogin() async throws {}
    func logout() async throws {}
    func listRecordings(since: Date) async throws -> [ExternalRecording] {
        throw ExternalSyncProviderError.needsLogin
    }

    func downloadAudio(remoteID: String, into directory: URL) async throws -> URL {
        throw ExternalSyncProviderError.needsLogin
    }
}

@MainActor
private final class ControllerNoopCapture: RecordingCapture {
    func permissionState() async -> RecordingPermissionState { .ready }
    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles { fatalError("unused") }
    func stop() async throws -> CapturedAudioFiles { fatalError("unused") }
}

@MainActor
private func waitUntil(_ timeoutSeconds: Double = 3, condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while !condition() {
        guard Date() < deadline else { return }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

/// Expiry notifies exactly once; later automatic attempts stay silent while a
/// manual attempt still reports its failure (AC9, AC12, D-12, D-19).
@Test @MainActor
func expiryNotifiesOnceAndOnlyManualRetriesReportAgain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    try store.bootstrap()
    let workspace = MeetingWorkspaceController(store: store, capture: ControllerNoopCapture())
    let notifier = SpyNotifier()
    let defaults = UserDefaults(suiteName: "external-sync-tests-\(UUID().uuidString)")!
    let controller = ExternalSyncController(
        workspace: workspace,
        providers: [ExpiringProvider()],
        notifier: notifier,
        defaults: defaults
    )

    controller.syncNow(providerID: "fakeprov")
    try await waitUntil { controller.providerState("fakeprov")?.needsRelogin == true }

    #expect(controller.providerState("fakeprov")?.needsRelogin == true)
    #expect(notifier.posts.count == 1)
    #expect(notifier.posts.first?.title.contains("Fake Service") == true)
    #expect(controller.statusLine != nil)

    // The hourly tick while expired never notifies again (D-12).
    await controller.autoTick()
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(notifier.posts.count == 1)

    // A manual attempt still reports its failure, but not as a new expiry.
    controller.syncNow(providerID: "fakeprov")
    try await waitUntil { notifier.posts.count >= 2 }
    #expect(notifier.posts.count == 2)
}

/// A provider that was never connected is skipped by the hourly tick: no
/// expiry badge and no notification before the first login (AC7, D-18).
@Test @MainActor
func autoTickSkipsProvidersThatWereNeverConnected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    try store.bootstrap()
    let workspace = MeetingWorkspaceController(store: store, capture: ControllerNoopCapture())
    let notifier = SpyNotifier()
    let defaults = UserDefaults(suiteName: "external-sync-tests-\(UUID().uuidString)")!

    final class NeverConnectedProvider: ExternalSyncProvider, @unchecked Sendable {
        let id = "fakeprov"
        let displayName = "Fake Service"
        func accountState() async -> ExternalSyncAccountState { .needsLogin }
        func beginLogin() async throws {}
        func logout() async throws {}
        func listRecordings(since: Date) async throws -> [ExternalRecording] {
            throw ExternalSyncProviderError.needsLogin
        }

        func downloadAudio(remoteID: String, into directory: URL) async throws -> URL {
            throw ExternalSyncProviderError.needsLogin
        }
    }

    let controller = ExternalSyncController(
        workspace: workspace,
        providers: [NeverConnectedProvider()],
        notifier: notifier,
        defaults: defaults
    )
    await controller.refreshAccountStates()

    await controller.autoTick()
    try await Task.sleep(nanoseconds: 300_000_000)

    #expect(notifier.posts.isEmpty)
    #expect(controller.providerState("fakeprov")?.needsRelogin == false)
    #expect(controller.statusLine == nil)
}

/// Manual sync posts a completion notification; automatic runs never do
/// (AC12, D-19).
@Test @MainActor
func manualSyncNotifiesCompletionWhileAutoSyncStaysInline() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    try store.bootstrap()
    let workspace = MeetingWorkspaceController(store: store, capture: ControllerNoopCapture())
    let notifier = SpyNotifier()
    let defaults = UserDefaults(suiteName: "external-sync-tests-\(UUID().uuidString)")!

    final class EmptyProvider: ExternalSyncProvider, @unchecked Sendable {
        let id = "fakeprov"
        let displayName = "Fake Service"
        func accountState() async -> ExternalSyncAccountState { .connected }
        func beginLogin() async throws {}
        func logout() async throws {}
        func listRecordings(since: Date) async throws -> [ExternalRecording] { [] }
        func downloadAudio(remoteID: String, into directory: URL) async throws -> URL {
            throw ExternalSyncProviderError.transientFailure("unused")
        }
    }

    let controller = ExternalSyncController(
        workspace: workspace,
        providers: [EmptyProvider()],
        notifier: notifier,
        defaults: defaults
    )

    // Automatic tick: the first run is due immediately, imports nothing, and
    // must not notify.
    await controller.refreshAccountStates()
    await controller.autoTick()
    try await waitUntil { controller.providerState("fakeprov")?.inlineResult != nil }
    #expect(notifier.posts.isEmpty)
    #expect(controller.providerState("fakeprov")?.inlineResult?.isEmpty == false)

    controller.syncNow(providerID: "fakeprov")
    try await waitUntil { !notifier.posts.isEmpty }
    #expect(notifier.posts.count == 1)
}
