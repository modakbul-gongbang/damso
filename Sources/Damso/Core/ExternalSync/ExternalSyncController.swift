import AVFoundation
import Foundation
import UserNotifications

// MARK: Notification boundary

protocol UserNotifying: Sendable {
    func post(title: String, body: String, userInfo: [String: String])
}

extension UserNotifying {
    func post(title: String, body: String) {
        post(title: title, body: body, userInfo: [:])
    }
}

/// Posts a macOS user notification. Only available from a bundled .app; a
/// bare `swift run` or test process silently skips instead of crashing the
/// UserNotifications framework. `userInfo` carries routing payloads (such as
/// the meeting stem behind a summary-completion notification) for the click
/// delegate.
struct SystemUserNotifier: UserNotifying {
    func post(title: String, body: String, userInfo: [String: String]) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = userInfo
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}

// MARK: Imported audio validation

enum ImportedAudioValidationError: Error, Equatable {
    case unplayable
    case emptyDuration
}

/// A downloaded file must decode and carry a positive duration before it may
/// enter the store; anything else is discarded and retried next sync (D-25).
enum ImportedAudioValidator {
    static func validatedDuration(of url: URL) throws -> Double {
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(contentsOf: url)
        } catch {
            throw ImportedAudioValidationError.unplayable
        }
        guard player.duration > 0 else { throw ImportedAudioValidationError.emptyDuration }
        return player.duration
    }
}

// MARK: Controller

/// App-side owner of every external sync provider: account state, the hourly
/// tick, manual sync, login/logout, per-provider enablement, badges, and
/// notifications. The provider list is the only place Plaud is named; the
/// rest of the flow is provider-neutral (R10).
@MainActor
final class ExternalSyncController: ObservableObject {
    struct ProviderViewState: Identifiable, Equatable {
        let id: String
        let displayName: String
        var accountState: ExternalSyncAccountState = .error("checking")
        var hasCheckedAccount = false
        var isSyncing = false
        var isConnecting = false
        var syncEnabled = true
        var lastSyncAt: Date?
        var inlineResult: String?
        var needsRelogin = false
        var lastFailureCode: String?
        var connectMessage: String?

        var isConnected: Bool { accountState == .connected && !needsRelogin }
    }

    @Published private(set) var providerStates: [ProviderViewState] = []

    private let providers: [any ExternalSyncProvider]
    private var engines: [String: ExternalSyncEngine] = [:]
    private let notifier: any UserNotifying
    private let defaults: UserDefaults
    private weak var workspace: MeetingWorkspaceController?
    private var tickTimer: Timer?
    private var notifiedExpiry: Set<String> = []

    init(
        workspace: MeetingWorkspaceController,
        providers: [any ExternalSyncProvider] = [PlaudCLIProvider()],
        notifier: any UserNotifying = SystemUserNotifier(),
        defaults: UserDefaults = .standard,
        scheduler: SyncScheduler = SyncScheduler()
    ) {
        self.workspace = workspace
        self.providers = providers
        self.notifier = notifier
        self.defaults = defaults
        let store = workspace.meetingStore
        providerStates = providers.map { provider in
            var state = ProviderViewState(id: provider.id, displayName: provider.displayName)
            state.syncEnabled = defaults.object(forKey: Self.enabledKey(provider.id)) as? Bool ?? true
            return state
        }
        for provider in providers {
            let checkpointStore = ExternalSyncCheckpointStore(
                fileURL: ExternalSyncCheckpointStore.fileURL(storeRoot: store.rootURL, providerID: provider.id)
            )
            engines[provider.id] = ExternalSyncEngine(
                provider: provider,
                scheduler: scheduler,
                checkpointStore: checkpointStore,
                importSink: Self.makeImportSink(providerID: provider.id, storeRoot: store.rootURL, workspace: workspace)
            )
        }
    }

    private static func enabledKey(_ providerID: String) -> String {
        "externalSync.\(providerID).enabled"
    }

    /// Maps a provider to the stored `MeetingSource`. The storage schema is
    /// locked (no new cases in this PRD); today's only provider is Plaud.
    nonisolated private static func meetingSource(for providerID: String) -> MeetingSource {
        MeetingSource(rawValue: providerID) ?? .plaud
    }

    /// Internal (not private) so the regression suite can drive the exact
    /// production import path against a temporary store.
    nonisolated static func makeImportSink(
        providerID: String,
        storeRoot: URL,
        workspace: MeetingWorkspaceController
    ) -> ExternalSyncEngine.ImportSink {
        { [weak workspace] recording, audioFile in
            let duration = try ImportedAudioValidator.validatedDuration(of: audioFile)
            let stem = "\(providerID)-\(recording.remoteID)"
            var record = MeetingRecord(
                stem: stem,
                source: Self.meetingSource(for: providerID),
                // An empty title falls back to the date-based display title;
                // the summary stage recomposes it later anyway (D-16).
                title: recording.title ?? "",
                createdAt: recording.startedAt,
                durationSeconds: duration
            )
            record.originalAudioFile = audioFile.lastPathComponent
            do {
                // A store instance is not thread-safe; the sink runs off the
                // main actor, so it commits through its own instance against
                // the same canonical root.
                try MeetingStore(root: storeRoot).commitImported(record, movingAudioFrom: audioFile)
            } catch MeetingStoreError.duplicateMeeting {
                // The meeting already exists locally; count as imported so the
                // watermark can advance instead of retrying forever.
                return
            }
            await MainActor.run {
                workspace?.noteExternalImport(stem: stem)
            }
        }
    }

    // MARK: Lifecycle

    /// Checks account states once and starts the minute tick that drives the
    /// hourly schedule (the scheduler itself decides when a tick really runs).
    func start() {
        Task { await refreshAccountStates() }
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.autoTick()
            }
        }
        tickTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func refreshAccountStates() async {
        for provider in providers {
            let account = await provider.accountState()
            let snapshot = await engines[provider.id]?.snapshot
            update(provider.id) { state in
                state.accountState = account
                state.hasCheckedAccount = true
                state.lastSyncAt = snapshot?.lastSuccessfulRun
                if account == .connected, snapshot?.authState == .requiresInteractiveLogin {
                    state.needsRelogin = true
                } else if account == .needsLogin, state.lastSyncAt != nil {
                    // A previously synced account whose token expired shows
                    // the re-login badge rather than a fresh "not connected".
                    state.needsRelogin = true
                } else if account == .connected {
                    state.needsRelogin = false
                }
            }
        }
    }

    // MARK: Sync

    /// One minute tick: every enabled, connected provider gets a scheduler
    /// poll. Automatic runs update inline state only and never notify (D-19).
    /// The spinner shows only for ticks the scheduler actually runs.
    func autoTick(now: Date = .now) async {
        for provider in providers {
            guard let engine = engines[provider.id] else { continue }
            guard let state = providerState(provider.id), state.syncEnabled, !state.isSyncing else { continue }
            // Never auto-sync an account that is not connected: a fresh,
            // never-connected provider must not produce "expired" badges or
            // notifications before its first login.
            guard state.isConnected else { continue }
            let recordingIsActive = workspace?.isRecording ?? false
            let decision = await engine.nextDecision(now: now, recordingIsActive: recordingIsActive)
            guard case .run = decision else {
                if decision == .waitForReauthentication {
                    apply(.waitingForReauthentication, providerID: provider.id, manual: false)
                }
                continue
            }
            markSyncingDuringRun(provider.id) {
                await engine.poll(now: now, recordingIsActive: recordingIsActive)
            } completion: { [weak self] status in
                self?.apply(status, providerID: provider.id, manual: false)
            }
        }
    }

    /// Sidebar "Sync now": skips the hourly window, shows inline progress,
    /// and additionally posts a completion/failure notification (D-19).
    func syncNow(providerID: String) {
        guard let engine = engines[providerID] else { return }
        guard providerState(providerID)?.isSyncing != true else { return }
        markSyncingDuringRun(providerID) {
            await engine.syncNow()
        } completion: { [weak self] status in
            self?.apply(status, providerID: providerID, manual: true)
        }
    }

    private func markSyncingDuringRun(
        _ providerID: String,
        run: @escaping () async -> ExternalSyncRunStatus,
        completion: @escaping @MainActor (ExternalSyncRunStatus) -> Void
    ) {
        update(providerID) { $0.isSyncing = true }
        Task { @MainActor in
            let status = await run()
            update(providerID) { $0.isSyncing = false }
            completion(status)
        }
    }

    private func apply(_ status: ExternalSyncRunStatus, providerID: String, manual: Bool) {
        let displayName = providerState(providerID)?.displayName ?? providerID
        switch status {
        case let .completed(imported, retryableFailures):
            update(providerID) { state in
                state.lastSyncAt = .now
                state.needsRelogin = false
                state.lastFailureCode = nil
                state.inlineResult = retryableFailures > 0
                    ? String(format: Loc.tr("Just synced · %d new, %d retrying"), imported, retryableFailures)
                    : String(format: Loc.tr("Just synced · %d new"), imported)
            }
            notifiedExpiry.remove(providerID)
            if manual {
                notifier.post(
                    title: String(format: Loc.tr("%@ sync finished"), displayName),
                    body: String(format: Loc.tr("%d new recordings were imported."), imported)
                )
            }
        case .authenticationExpired, .waitingForReauthentication:
            update(providerID) { state in
                state.needsRelogin = true
                state.inlineResult = nil
            }
            // The expiry notification fires once per expiry, never per retry
            // (D-12); a manual attempt still reports its failure.
            if !notifiedExpiry.contains(providerID) {
                notifiedExpiry.insert(providerID)
                notifier.post(
                    title: String(format: Loc.tr("%@ needs a re-login"), displayName),
                    body: Loc.tr("Sync is paused until you sign in again from Settings.")
                )
            } else if manual {
                notifier.post(
                    title: String(format: Loc.tr("%@ sync failed"), displayName),
                    body: Loc.tr("Sync is paused until you sign in again from Settings.")
                )
            }
        case .transientFailure:
            update(providerID) { state in
                state.lastFailureCode = "transient"
                state.inlineResult = Loc.tr("Sync failed · will retry")
            }
            if manual {
                notifier.post(
                    title: String(format: Loc.tr("%@ sync failed"), displayName),
                    body: Loc.tr("The service could not be reached. Sync retries automatically.")
                )
            }
        case .notInstalled:
            update(providerID) { state in
                state.accountState = .notInstalled(guidance: PlaudCLIProvider.installGuidanceCommand)
                state.inlineResult = nil
            }
        case .statePersistenceFailed:
            update(providerID) { state in
                state.lastFailureCode = "state_persistence_failed"
                state.inlineResult = Loc.tr("Sync is blocked: its local state file is unwritable.")
            }
        case .idle, .deferredForRecording, .backingOff, .alreadyRunning:
            break
        }
    }

    // MARK: Connect / disconnect

    /// Asynchronous connect with spinner: the provider owns the browser OAuth
    /// and its two-minute timeout; the button is restored with a message when
    /// login does not finish (D-27).
    func connect(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        guard providerState(providerID)?.isConnecting != true else { return }
        update(providerID) { state in
            state.isConnecting = true
            state.connectMessage = nil
        }
        Task { @MainActor in
            do {
                try await provider.beginLogin()
                await engines[providerID]?.didCompleteInteractiveLogin()
                notifiedExpiry.remove(providerID)
                update(providerID) { state in
                    state.isConnecting = false
                    state.accountState = .connected
                    state.needsRelogin = false
                    state.connectMessage = nil
                }
                // First connect pulls the initial window right away instead
                // of waiting for the next hourly tick (UX-03).
                syncNow(providerID: providerID)
            } catch {
                update(providerID) { state in
                    state.isConnecting = false
                    state.connectMessage = Loc.tr("The login did not finish. Try again.")
                }
            }
        }
    }

    func disconnect(providerID: String) {
        guard let provider = providers.first(where: { $0.id == providerID }) else { return }
        Task { @MainActor in
            try? await provider.logout()
            update(providerID) { state in
                state.accountState = .needsLogin
                state.needsRelogin = false
                state.inlineResult = nil
                state.lastSyncAt = nil
            }
            notifiedExpiry.remove(providerID)
        }
    }

    func setSyncEnabled(_ enabled: Bool, providerID: String) {
        defaults.set(enabled, forKey: Self.enabledKey(providerID))
        update(providerID) { $0.syncEnabled = enabled }
    }

    // MARK: Status surfaces

    /// One-line badge summary for the menu bar footer; nil when nothing
    /// needs attention.
    var statusLine: String? {
        let needing = providerStates.filter { $0.needsRelogin }
        guard let first = needing.first else { return nil }
        return String(format: Loc.tr("%@ needs a re-login"), first.displayName)
    }

    func providerState(_ providerID: String) -> ProviderViewState? {
        providerStates.first { $0.id == providerID }
    }

    private func update(_ providerID: String, _ mutate: (inout ProviderViewState) -> Void) {
        guard let index = providerStates.firstIndex(where: { $0.id == providerID }) else { return }
        mutate(&providerStates[index])
    }
}
