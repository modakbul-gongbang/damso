import Foundation
import OSLog

enum MeetingWorkspaceState: Equatable {
    case ready
    case checkingPermissions
    case recording
    case processing
    case speakerReview(Int)
    case failed(String)

    var message: String {
        switch self {
        case .ready:
            "Ready to capture"
        case .checkingPermissions:
            "Waiting for recording permissions"
        case .recording:
            "Recording in progress"
        case .processing:
            "Processing locally"
        case .speakerReview(let count):
            "\(count) speakers need review"
        case .failed:
            "Recording needs attention"
        }
    }
}

private struct PhaseOneTranscriptProvenance: Decodable {
    let sourceFile: String
    let sourceFiles: [String]?

    enum CodingKeys: String, CodingKey {
        case sourceFile = "source_file"
        case sourceFiles = "source_files"
    }
}

/// The nine synchronous processing/people RPC operations the workspace talks
/// to (D-13: phase-one and summary moved off this protocol entirely - they
/// are queue-based now, triggered and polled through `RemoteMeetingStore`
/// directly). The production backend POSTs to the daemon's `/v1/rpc`; tests
/// substitute an in-memory backend so pipeline behavior is regression-tested
/// without a real HTTP round trip.
protocol LocalProcessingBackend: Sendable {
    func recluster(_ request: LocalReclusterRequest) throws -> LocalProcessingResult
    func applyResolutions(_ request: LocalResolutionProcessingRequest) throws -> LocalProcessingResult
    func appendPersonNote(_ request: LocalPersonNoteRequest) throws -> LocalProcessingResult
    func refreshCandidates(_ request: LocalRefreshCandidatesRequest) throws -> LocalProcessingResult
    func setPersonEmail(_ request: LocalPersonEmailRequest) throws -> LocalProcessingResult
    func removePersonAlias(_ request: LocalRemovePersonAliasRequest) throws -> LocalProcessingResult
    func suggestSpeakers(_ request: LocalSpeakerHintsRequest) throws -> LocalSpeakerHintsResult
    func cleanTranscript(_ request: LocalTranscriptCleanupRequest) throws -> LocalTranscriptCleanupResult
    func rebuildIndex(storeRoot: String) throws -> LocalIndexResult
}

struct SystemProcessingBackend: LocalProcessingBackend {
    private let client: DamsoHTTPClient

    init(client: DamsoHTTPClient = DamsoHTTPClient()) {
        self.client = client
    }

    func recluster(_ request: LocalReclusterRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.recluster(request, client: client)
    }

    func applyResolutions(_ request: LocalResolutionProcessingRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.applyResolutions(request, client: client)
    }

    func appendPersonNote(_ request: LocalPersonNoteRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.appendPersonNote(request, client: client)
    }

    func refreshCandidates(_ request: LocalRefreshCandidatesRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.refreshCandidates(request, client: client)
    }

    func setPersonEmail(_ request: LocalPersonEmailRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.setPersonEmail(request, client: client)
    }

    func removePersonAlias(_ request: LocalRemovePersonAliasRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.removePersonAlias(request, client: client)
    }

    func suggestSpeakers(_ request: LocalSpeakerHintsRequest) throws -> LocalSpeakerHintsResult {
        try LocalSpeakerHintsProcessRunner.run(request, client: client)
    }

    func cleanTranscript(_ request: LocalTranscriptCleanupRequest) throws -> LocalTranscriptCleanupResult {
        try LocalTranscriptCleanupProcessRunner.run(request, client: client)
    }

    func rebuildIndex(storeRoot: String) throws -> LocalIndexResult {
        try LocalIndexProcessRunner.rebuild(storeRoot: storeRoot, client: client)
    }
}

/// Connects the primary record action to the local store, native capture, and
/// narrow Python phase-one boundary. All heavy processing runs off the UI actor.
@MainActor
final class MeetingWorkspaceController: ObservableObject {
    private static let recordingLogger = Logger(subsystem: "com.yansfil.damso", category: "recording")
    @Published private(set) var state: MeetingWorkspaceState = .ready
    /// Wall-clock start of the active recording, for elapsed-time display.
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recoveryAction: String?
    @Published private(set) var records: [MeetingRecord] = []
    @Published private(set) var people: [LocalPersonProfile] = []
    @Published private(set) var selectedRecord: MeetingRecord?
    @Published private(set) var processingArtifacts = MeetingProcessingArtifacts.empty
    @Published private(set) var isApplyingSpeakerResolution = false
    @Published private(set) var isReclustering = false
    @Published private(set) var isRequestingSummary = false
    @Published private(set) var speakerSuggestions: [String: [SpeakerSuggestion]] = [:]
    @Published private(set) var isSuggestingSpeakers = false
    /// R9(b): nil on a local/combined store, where the whole notion of
    /// "connected to the mini" does not apply and the UI should show nothing.
    /// Polled from `RemoteConnectivityTracker` rather than pushed, since that
    /// tracker is written from background tasks all over Core and has no
    /// observer list of its own.
    @Published private(set) var connectionStatus: RemoteConnectivityTracker.Status?
    /// R9(d): outbox records not yet handed off to the mini. 0 on a
    /// local/combined store.
    @Published private(set) var outboxPendingCount: Int = 0
    /// Optional pre-recording plan the user sets next to the Record button on
    /// either surface (main window or menu-bar card). `plannedSpeakerCount` of 0
    /// means "unknown / let diarization decide"; a positive value pins the
    /// diarizer to exactly that many speakers, which is the only reliable way to
    /// stop over-segmentation on low-quality audio. Starts at
    /// `SpeakerPlan.defaultCount` rather than Auto, since two-person calls are
    /// the common case this app records. Consumed and reset by `startNow()`.
    @Published var plannedSpeakerCount: Int = SpeakerPlan.defaultCount
    @Published var plannedParticipants: [String] = [] {
        didSet {
            plannedSpeakerCount = SpeakerPlan.prefilledCount(
                current: plannedSpeakerCount,
                oldParticipants: oldValue,
                newParticipants: plannedParticipants
            )
        }
    }

    private let store: any MeetingStoring
    private let capture: any RecordingCapture
    private let session: RecordingSessionController
    private let backend: any LocalProcessingBackend
    private let notifier: any UserNotifying
    private let audioFetcher: RemoteAudioFetcher
    private var activeRecord: MeetingRecord?
    /// D-13: the server's own queue is the single serialization point now
    /// (one job at a time, its own retry state) - this only tracks which
    /// stems this instance is actively polling, so a second poll loop is
    /// never started for the same stem concurrently.
    private var pollingStems: Set<String> = []
    private var refreshedCandidateStems: Set<String> = []
    private var suggestedStems: Set<String> = []
    private var cleanedTranscriptStems: Set<String> = []
    /// R7's fourth cache-sync trigger (the 5-10 minute periodic one; the
    /// other three - launch, main-window refresh, post-write - all ride
    /// along on `performRemoteMaintenanceIfNeeded()` from existing call
    /// sites). nil on a local store.
    private var remoteMaintenanceTimer: Timer?
    /// R8's launch-and-periodic sweep trigger, independent of whether the
    /// main window is ever shown (AC10 - a menu-bar-resident mini has no
    /// window to open one for). Runs unconditionally, local or remote.
    private var processingSweepTimer: Timer?
    /// R9(b): polls `RemoteConnectivityTracker` into `connectionStatus` so the
    /// indicator reflects background remote calls, not just user-initiated
    /// ones. Deliberately short (a plain lock-guarded enum read, no I/O) so a
    /// drop or recovery shows up promptly. nil on a local/combined store.
    private var connectionStatusPollTimer: Timer?
    /// Defaults to the process-wide singleton; tests inject a fresh instance
    /// so `guardRemoteWrite`/the indicator can be driven to a known status
    /// deterministically instead of depending on whatever a real HTTP
    /// attempt elsewhere in the test run last left `.shared` at.
    private let connectivityTracker: RemoteConnectivityTracker

    init(store: (any MeetingStoring)? = nil, capture: any RecordingCapture = LocalRecordingCoordinator(), backend: any LocalProcessingBackend = SystemProcessingBackend(), notifier: any UserNotifying = SystemUserNotifier(), audioFetcher: RemoteAudioFetcher = RemoteAudioFetcher(), connectivityTracker: RemoteConnectivityTracker = .shared) {
        self.store = store ?? Self.defaultStore()
        self.capture = capture
        self.backend = backend
        self.notifier = notifier
        self.audioFetcher = audioFetcher
        self.connectivityTracker = connectivityTracker
        session = RecordingSessionController(capture: capture)
        // Do not create the default store merely by opening the app. This keeps
        // a denied first recording attempt side-effect free while still showing
        // an already-configured library immediately on later launches.
        if self.store.isConfigured {
            refreshLibrary()
            resumePollingUnfinishedProcessing()
        }
        if let remote = self.store as? RemoteMeetingStore {
            connectionStatus = connectivityTracker.status
            outboxPendingCount = remote.outboxPendingCount()
        }
        startRemoteMaintenanceTimerIfNeeded()
        startConnectionStatusPollTimerIfNeeded()
    }

    /// 7 minutes: inside R7's stated 5-10 minute window. Also the periodic
    /// safety net that retries any outbox record a disconnected server left
    /// stranded (D-13 moved processing orchestration itself entirely
    /// server-side, so this client-side sweep only needs to keep the outbox
    /// draining and the read cache fresh - it never decides when processing
    /// runs).
    private static let remoteMaintenanceInterval: TimeInterval = 7 * 60
    /// 5 seconds: cheap enough to poll often, since it is only a lock-guarded
    /// enum read - no HTTP call of its own (R9b).
    private static let connectionStatusPollInterval: TimeInterval = 5

    /// Local mode never needs this - `RemoteMeetingStore.syncCache()` is
    /// already a no-op there, and running a repeating Timer for a sync that
    /// never does anything is needless RunLoop churn (every test's workspace
    /// instance would otherwise accumulate one for the lifetime of the test
    /// process).
    private func startRemoteMaintenanceTimerIfNeeded() {
        guard let remote = store as? RemoteMeetingStore, remote.isRemoteConnection else { return }
        let timer = Timer(timeInterval: Self.remoteMaintenanceInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.performRemoteMaintenanceIfNeeded()
            }
        }
        remoteMaintenanceTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startConnectionStatusPollTimerIfNeeded() {
        guard let remote = store as? RemoteMeetingStore, remote.isRemoteConnection else { return }
        let timer = Timer(timeInterval: Self.connectionStatusPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshConnectionStatus()
            }
        }
        connectionStatusPollTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshConnectionStatus() {
        guard let remote = store as? RemoteMeetingStore else { return }
        connectionStatus = connectivityTracker.status
        outboxPendingCount = remote.outboxPendingCount()
    }

    /// D-13: on launch, any record still sitting in `.queued`/`.transcribing`/
    /// `.summarizing` was left mid-flight by a quit or crash. The server's own
    /// queue already resumed the actual work on its side
    /// (`recover_incomplete_on_startup`); this only resumes this client's
    /// status polling so the UI stops showing a stale "in progress" state
    /// once the server finishes or fails it.
    private func resumePollingUnfinishedProcessing() {
        for record in records where record.stage == .queued || record.stage == .transcribing || record.stage == .summarizing {
            beginPollingProcessing(stem: record.stem)
        }
        // `.captured` records never even reached the trigger call before a
        // crash interrupted them (both local recordings and external
        // imports commit through the same outbox path now, D-14) -
        // `processImportedMeeting` is idempotent and handles either case.
        for record in records where record.stage == .captured {
            processImportedMeeting(stem: record.stem)
        }
    }

    /// The one store this app now ever constructs (D-05: local mode routes
    /// through the same HTTP daemon a remote mode does, just over loopback
    /// with no auth) - `ServerConnectionMode` alone decides local vs. remote,
    /// never a separate store class.
    private static func defaultStore() -> any MeetingStoring {
        let connectionConfiguration = ServerConnectionConfiguration()
        let client = DamsoHTTPClient(configuration: connectionConfiguration)
        let outboxRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Damso/Outbox", isDirectory: true)
        switch connectionConfiguration.mode {
        case .local:
            // The "cache" is the real canonical store directory - same disk,
            // same machine, nothing to mirror (RemoteMeetingStore's
            // needsCacheSync: false skips the changes-based sync entirely).
            let root = StorageRootConfiguration().rootURL
            return RemoteMeetingStore(client: client, connectionConfiguration: connectionConfiguration, cacheRoot: root, outboxRoot: outboxRoot, needsCacheSync: false)
        case .remote:
            let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Damso", isDirectory: true)
            return RemoteMeetingStore(client: client, connectionConfiguration: connectionConfiguration, cacheRoot: cacheRoot, outboxRoot: outboxRoot, needsCacheSync: true)
        }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    var isCaptureStartPending: Bool {
        if case .checkingPermissions = state { return true }
        return false
    }

    var hints: MeetingHints {
        session.hints
    }

    func performPrimaryAction() async {
        if isRecording {
            await stopAndProcess()
        } else {
            await startNow()
        }
    }

    /// Folds the optional pre-recording plan (speaker count, participant names)
    /// into a base hint set. A count of 0 leaves diarization on auto; planned
    /// participant names are appended case-insensitively without duplicating
    /// names the base hints already carry.
    func plannedHints(basedOn base: MeetingHints) -> MeetingHints {
        var hints = base
        if plannedSpeakerCount > 0 {
            hints.numSpeakers = plannedSpeakerCount
        }
        if !plannedParticipants.isEmpty {
            var participants = hints.participants
            for name in plannedParticipants {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      !participants.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
                participants.append(trimmed)
            }
            hints.participants = participants
        }
        return hints
    }

    func updateHints(_ hints: MeetingHints) {
        session.updateHints(hints)
        guard var record = activeRecord else { return }
        record.hints = hints
        if let topic = hints.topic, !topic.isEmpty {
            record.title = topic
        }
        try? store.update(record)
        activeRecord = record
        replace(record)
    }

    func refreshLibrary() {
        do {
            records = try store.list()
            people = try store.listPeople(records: records)
            if let activeRecord, let refreshed = records.first(where: { $0.stem == activeRecord.stem }) {
                self.activeRecord = refreshed
            }
            let requestedStem = selectedRecord?.stem ?? activeRecord?.stem
            if let requestedStem, let record = records.first(where: { $0.stem == requestedStem }) {
                select(record)
            } else if let first = records.first {
                select(first)
            } else {
                selectedRecord = nil
                processingArtifacts = .empty
            }
        } catch {
            state = .failed("storage_unavailable")
            recoveryAction = Loc.tr("Choose a writable local storage root, then retry.")
        }
        performRemoteMaintenanceIfNeeded()
    }

    /// A no-op on a local store. On a remote store this is one of R7's four
    /// cache-sync trigger points (app launch and every later main-window
    /// refresh both call `refreshLibrary()` already, so both ride along here
    /// without a dedicated timer - `cacheSyncTimer` below covers the fourth,
    /// the 5-10 minute periodic trigger) and also the retry point for an
    /// outbox handoff a disconnected mini interrupted (R6, R9). Cache syncs
    /// first: `retryPendingOutboxWork`'s audio-deletion gate reads the cache's
    /// phase-one confirmation, so a stale cache would delay it a cycle.
    /// Effects land on the *next* refresh, not this call - kept that way to
    /// avoid refreshLibrary re-triggering itself.
    private func performRemoteMaintenanceIfNeeded() {
        guard let remote = store as? RemoteMeetingStore else { return }
        Task { @MainActor in
            await remote.syncCache()
            await remote.retryPendingOutboxWork()
            self.refreshConnectionStatus()
        }
    }

    /// R9(c): blocks a write attempt (or audio playback) at the moment the
    /// user tries it, using the last known status rather than a fresh probe -
    /// a fresh ssh round trip on every click would make every write feel
    /// slow even when the connection is fine. A stale "connected" verdict
    /// just lets the attempt run and fail on its own (AC8's path); this can
    /// never make an attempt succeed that a live check would have blocked.
    /// Always true on a local/combined store, where none of this applies.
    private func guardRemoteWrite() -> Bool {
        guard store is RemoteMeetingStore, let connectionStatus, connectionStatus != .connected else { return true }
        recoveryAction = connectionStatus == .versionMismatch
            ? Loc.tr("The Mac mini needs a Damso update before this can run.")
            : Loc.tr("Available once connected to the Mac mini.")
        return false
    }

    func select(stem: String) {
        guard let record = records.first(where: { $0.stem == stem }) else { return }
        select(record)
    }

    func applyResolution(speaker: String, action: SpeakerResolutionAction, personName: String? = nil, alias: String? = nil) async {
        guard guardRemoteWrite() else { return }
        guard var record = selectedRecord else { return }
        let cleanedName = personName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard action == .skip || (cleanedName?.isEmpty == false) else { return }
        let cleanedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolutions = Dictionary(uniqueKeysWithValues: record.resolutions.map { ($0.speaker, $0) })
        resolutions[speaker] = SpeakerResolution(
            speaker: speaker,
            action: action,
            personName: action == .skip ? nil : cleanedName,
            alias: action == .skip ? nil : (cleanedAlias?.isEmpty == false ? cleanedAlias : nil)
        )
        let request = LocalResolutionProcessingRequest(
            recordingDirectory: store.recordDirectoryPath(stem: record.stem),
            peoplesDirectory: store.peoplesDirectoryPath,
            meetingDate: Self.meetingDate.string(from: record.createdAt),
            resolutions: Dictionary(uniqueKeysWithValues: resolutions.map { key, value in
                (key, LocalSpeakerResolution(action: value.action.rawValue, name: value.personName, alias: value.alias))
            })
        )
        isApplyingSpeakerResolution = true
        let result = await Task.detached(priority: .utility) { [backend] in
            Result { try backend.applyResolutions(request) }
        }.value
        isApplyingSpeakerResolution = false
        switch result {
        case .success:
            // Confirming a profile-backed name revives it if it was deleted
            // from People earlier (the backend just recreated the folder).
            if let cleanedName, action == .match || action == .new || action == .me {
                store.unmarkPersonDeleted(cleanedName)
            }
            record.resolutions = resolutions.values.sorted { $0.speaker < $1.speaker }
            let allResolved = processingArtifacts.proposals.allSatisfy { resolutions[$0.speaker] != nil }
            let alreadySummarized = record.summary != nil
            record.stage = allResolved ? (alreadySummarized ? .complete : .speakerReview) : .speakerReview
            record.completedStages = [.captured, .transcribing, .speakerReview]
            if alreadySummarized {
                record.completedStages += [.summarizing, .complete]
            }
            record.lastErrorCode = nil
            do {
                try store.update(record)
                activeRecord = record.stem == activeRecord?.stem ? record : activeRecord
                replace(record)
                selectedRecord = record
                processingArtifacts = try store.processingArtifacts(stem: record.stem)
                people = try store.listPeople(records: records)
                recoveryAction = nil
                scheduleIndexRebuild()
                performRemoteMaintenanceIfNeeded()
                // Summary is no longer auto-started when the last speaker is
                // confirmed; the user presses "Generate summary" explicitly so
                // transcripts are sent to the agent only on demand.
            } catch {
                state = .failed("speaker_resolution_save_failed")
                recoveryAction = Loc.tr("The local speaker result could not be saved. Retry this card.")
            }
        case .failure:
            state = .failed("speaker_resolution_failed")
            recoveryAction = Loc.tr("The local speaker result was not changed. Retry this card after checking local processing diagnostics.")
        }
    }

    /// Triggers the summary and title step for a record whose transcript is
    /// ready (D-13: the server's queue runs it - this only starts the job and
    /// begins polling). Also serves as the manual retry entry point after a
    /// failed summary stage, and is called automatically once by the server
    /// itself right after `apply-resolutions` succeeds; the explicit call
    /// here covers regenerating a summary later, which needs no speaker
    /// re-confirmation.
    func runSummary(for target: MeetingRecord? = nil) async {
        guard guardRemoteWrite() else { return }
        guard var record = target ?? selectedRecord else { return }
        guard !pollingStems.contains(record.stem) else { return }
        guard let remote = store as? RemoteMeetingStore else {
            recoveryAction = Loc.tr("Server storage is not configured. Set it up in Settings.")
            return
        }
        let artifacts = (try? store.processingArtifacts(stem: record.stem)) ?? .empty
        guard !artifacts.transcript.isEmpty else {
            recoveryAction = Loc.tr("Finish local transcription before the summary step can run.")
            return
        }
        record.stage = .summarizing
        record.lastErrorCode = nil
        do {
            try store.update(record)
            replace(record)
            if selectedRecord?.stem == record.stem { selectedRecord = record }
        } catch {
            state = .failed("summary_state_save_failed")
            recoveryAction = Loc.tr("The summary step could not be prepared. Check local storage and retry.")
            return
        }

        isRequestingSummary = true
        state = .processing
        do {
            try await remote.triggerSummary(
                stem: record.stem,
                agent: AgentPreferences.summaryAgent().rawValue,
                language: AgentPreferences.language().rawValue,
                meetingDate: LocalSummaryRequest.localMeetingDate(for: record.createdAt)
            )
        } catch {
            isRequestingSummary = false
            saveSummaryFailure(record, code: "summary_launch_failed")
            return
        }
        isRequestingSummary = false
        beginPollingProcessing(stem: record.stem)
    }

    /// Summary just completed: when date-resolved action items exist and the
    /// user keeps the notification toggle on, one notification offers the
    /// calendar candidates; clicking it routes back to this meeting (D-07).
    private func postCalendarCandidateNotification(for record: MeetingRecord) {
        let candidates = ActionItemCalendarPlanner.candidates(from: record.summary)
        guard SummaryCalendarNotification.shouldNotify(
            candidateCount: candidates.count,
            enabled: CalendarPreferences.notificationEnabled()
        ) else { return }
        let content = SummaryCalendarNotification.content(meetingTitle: record.title, candidateCount: candidates.count)
        notifier.post(
            title: content.title,
            body: content.body,
            userInfo: [SummaryCalendarNotification.stemUserInfoKey: record.stem]
        )
    }

    /// Persists calendar event links created for this meeting's action items.
    /// Links accumulate; the (task, dueDate) identity keeps one item from
    /// being recorded twice while re-summarized items become new candidates.
    func appendCalendarLinks(_ links: [CalendarEventLink], stem: String) {
        guard !links.isEmpty, var record = records.first(where: { $0.stem == stem }) else { return }
        var merged = record.calendarEventLinks ?? []
        for link in links where !merged.contains(where: { $0.task == link.task && $0.dueDate == link.dueDate }) {
            merged.append(link)
        }
        record.calendarEventLinks = merged
        do {
            try store.update(record)
            replace(record)
            if selectedRecord?.stem == record.stem { selectedRecord = record }
        } catch {
            recoveryAction = Loc.tr("The calendar link could not be saved to this meeting.")
        }
    }

    /// D-13: starts (or rejoins) polling `/v1/recordings/{stem}/status` until
    /// the server's queue settles the job it is already running - this
    /// replaces every "spawn a subprocess and await its result" call site
    /// (phase-one after an upload, summary after a trigger) with one shared
    /// poll loop, since the server, not this client, now owns running and
    /// retrying the actual work.
    private func beginPollingProcessing(stem: String, intervalSeconds: UInt64 = 2) {
        guard !pollingStems.contains(stem), let remote = store as? RemoteMeetingStore else { return }
        pollingStems.insert(stem)
        Task { [weak self] in
            defer { self?.pollingStems.remove(stem) }
            while true {
                guard let self else { return }
                let status = try? await remote.processingStatus(stem: stem)
                guard let status else {
                    try? await Task.sleep(for: .seconds(intervalSeconds))
                    continue
                }
                switch status.state {
                case "done":
                    self.handleProcessingCompleted(stem: stem, kind: status.kind)
                    return
                case "failed":
                    self.handleProcessingFailed(stem: stem, kind: status.kind, message: status.error)
                    return
                default:
                    try? await Task.sleep(for: .seconds(intervalSeconds))
                }
            }
        }
    }

    /// `kind` distinguishes which job just settled: "phase-one" moves the
    /// record into speaker review (mirrors the old `finishProcessing`);
    /// "summary" writes the stored summary artifact into the record (mirrors
    /// the old success branch of `runSummary`).
    private func handleProcessingCompleted(stem: String, kind: String?) {
        guard var record = try? store.load(stem: stem) else { return }
        switch kind {
        case "summary":
            do {
                guard let artifact = try store.storedSummaryArtifact(stem: stem) else {
                    throw LocalSummaryCommandError.invalidResponse
                }
                record.summary = artifact.summary
                if let agentTitle = artifact.agentTitle, !agentTitle.isEmpty {
                    record.title = MeetingTitleComposer.compose(agentTitle: agentTitle, createdAt: record.createdAt)
                }
                record.personNotes = mergedPersonNotes(existing: record.personNotes, proposed: artifact.personNotes)
                record.stage = .complete
                record.completedStages = [.captured, .transcribing, .speakerReview, .summarizing, .complete]
                try store.update(record)
                replace(record)
                if selectedRecord?.stem == stem { selectedRecord = record }
                if activeRecord?.stem == stem || selectedRecord?.stem == stem { state = .ready }
                recoveryAction = nil
                scheduleIndexRebuild()
                performRemoteMaintenanceIfNeeded()
                postCalendarCandidateNotification(for: record)
            } catch {
                saveSummaryFailure(record, code: "summary_artifact_invalid")
            }
        default:
            Task { [weak self] in
                await self?.finishPhaseOne(stem: stem)
            }
        }
    }

    /// Phase-one just settled server-side. Two audio sources (mic + system)
    /// mean the server also produced a merged `combined-audio.m4a` for
    /// playback; this pulls it down before trusting it as
    /// `processedAudioFile` - the status poll response carries no payload of
    /// its own to name it (unlike the SSH-era direct `runPhaseOne` response),
    /// so its presence on the server is the proof.
    private func finishPhaseOne(stem: String) async {
        guard var record = try? store.load(stem: stem) else { return }
        var processedAudioFile: String?
        if record.systemAudioFile != nil, let remote = store as? RemoteMeetingStore {
            let destination = recordDirectory(for: record).appendingPathComponent("combined-audio.m4a")
            do {
                try await remote.pullFile(stem: stem, filename: "combined-audio.m4a", to: destination)
                processedAudioFile = "combined-audio.m4a"
            } catch {
                record.stage = .failed
                record.lastErrorCode = "combined_audio_unavailable"
                record.processedAudioFile = nil
                try? store.update(record)
                if activeRecord?.stem == stem { activeRecord = record }
                replace(record)
                if selectedRecord?.stem == stem {
                    selectedRecord = record
                    state = .failed("combined_audio_unavailable")
                    recoveryAction = Loc.tr("The combined playback audio was not created safely. Restore both captured tracks and retry local processing.")
                }
                return
            }
        }
        record.stage = .speakerReview
        record.completedStages = [.captured, .transcribing, .speakerReview]
        record.processedAudioFile = processedAudioFile
        record.lastErrorCode = nil
        try? store.update(record)
        if activeRecord?.stem == stem { activeRecord = record }
        replace(record)
        if selectedRecord?.stem == stem {
            selectedRecord = record
            processingArtifacts = (try? store.processingArtifacts(stem: stem)) ?? .empty
            state = .speakerReview(processingArtifacts.proposals.count)
        }
        recoveryAction = nil
        warmSpeakerSuggestions(stem: stem)
        performRemoteMaintenanceIfNeeded()
    }

    private func handleProcessingFailed(stem: String, kind: String?, message: String?) {
        guard var record = try? store.load(stem: stem) else { return }
        if kind == "summary" {
            saveSummaryFailure(record, code: message ?? "summary_unavailable")
            return
        }
        record.stage = .failed
        record.lastErrorCode = message ?? "local_processing_failed"
        try? store.update(record)
        if activeRecord?.stem == stem { activeRecord = record }
        replace(record)
        if selectedRecord?.stem == stem {
            selectedRecord = record
            state = .failed(record.lastErrorCode ?? "local_processing_failed")
            recoveryAction = Loc.tr("Processing failed on the server. Check server diagnostics and retry.")
        }
    }

    func acceptPersonNote(_ proposal: PersonNoteProposal, editedNote: String? = nil) async {
        guard guardRemoteWrite() else { return }
        guard var record = selectedRecord else { return }
        let noteText = (editedNote ?? proposal.note).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !noteText.isEmpty else { return }
        let request = LocalPersonNoteRequest(
            recordingDirectory: store.recordDirectoryPath(stem: record.stem),
            peoplesDirectory: store.peoplesDirectoryPath,
            meetingDate: Self.meetingDate.string(from: record.createdAt),
            name: proposal.name,
            note: noteText
        )
        let result = await Task.detached(priority: .utility) { [backend] in
            Result { try backend.appendPersonNote(request) }
        }.value
        switch result {
        case .success:
            updatePersonNote(in: &record, matching: proposal, to: .accepted, note: noteText)
            try? store.update(record)
            replace(record)
            selectedRecord = record
            recoveryAction = nil
        case .failure:
            recoveryAction = Loc.tr("The profile note was not saved. The profile file stays unchanged; retry from this proposal.")
        }
    }

    func rejectPersonNote(_ proposal: PersonNoteProposal) {
        guard guardRemoteWrite() else { return }
        guard var record = selectedRecord else { return }
        updatePersonNote(in: &record, matching: proposal, to: .rejected, note: proposal.note)
        try? store.update(record)
        replace(record)
        selectedRecord = record
    }

    /// Permanently deletes one meeting after the UI's explicit confirmation.
    /// A meeting that is still recording or processing is refused so the
    /// active pipeline cannot resurrect or write into a removed directory.
    func deleteMeeting(stem: String) {
        if activeRecord?.stem == stem, isRecording || isCaptureStartPending {
            recoveryAction = Loc.tr("Stop the recording before deleting this meeting.")
            return
        }
        if activeRecord?.stem == stem, state == .processing {
            recoveryAction = Loc.tr("Wait for local processing to finish before deleting this meeting.")
            return
        }
        do {
            try store.delete(stem: stem)
        } catch {
            recoveryAction = Loc.tr("The meeting could not be deleted. Check local storage and retry.")
            return
        }
        if activeRecord?.stem == stem { activeRecord = nil }
        records.removeAll { $0.stem == stem }
        if selectedRecord?.stem == stem {
            if let next = records.first {
                select(next)
            } else {
                selectedRecord = nil
                processingArtifacts = .empty
            }
        }
        people = (try? store.listPeople(records: records)) ?? people
        recoveryAction = nil
        scheduleIndexRebuild()
    }

    func rebuildSearchIndex() async -> Bool {
        let root = store.storeRootPath
        let result = await Task.detached(priority: .utility) { [backend] in
            Result { try backend.rebuildIndex(storeRoot: root) }
        }.value
        if case .success = result { return true }
        return false
    }

    var duplicateStems: Set<String> {
        DuplicateSuspects.stems(in: records)
    }

    func profileNotes(for person: LocalPersonProfile) -> String? {
        store.profileNotes(name: person.name)
    }

    /// Voice candidates freeze at transcription time while profiles keep
    /// learning; recompute them once per session when an unresolved meeting
    /// is opened so recommendations reflect today's profiles.
    func refreshCandidatesIfNeeded(for record: MeetingRecord) {
        guard record.stage == .speakerReview, !refreshedCandidateStems.contains(record.stem) else { return }
        refreshedCandidateStems.insert(record.stem)
        let request = LocalRefreshCandidatesRequest(
            recordingDirectory: store.recordDirectoryPath(stem: record.stem),
            peoplesDirectory: store.peoplesDirectoryPath
        )
        let stem = record.stem
        Task { [weak self, backend] in
            let result = await Task.detached(priority: .utility) {
                Result { try backend.refreshCandidates(request) }
            }.value
            guard let self, case .success = result, self.selectedRecord?.stem == stem else { return }
            self.processingArtifacts = (try? self.store.processingArtifacts(stem: stem)) ?? self.processingArtifacts
        }
    }

    /// The cheap-model artifact cleanup runs once per transcribed meeting the
    /// first time it is opened. It only writes the overlay file; the original
    /// transcript files are never touched, so failures are silent and safe.
    func requestTranscriptCleanupIfNeeded(for record: MeetingRecord) {
        guard record.stage == .speakerReview || record.stage.isTerminal || record.stage == .summarizing else { return }
        guard !processingArtifacts.transcript.isEmpty else { return }
        guard !cleanedTranscriptStems.contains(record.stem), !store.hasCleanupOverlay(stem: record.stem) else { return }
        cleanedTranscriptStems.insert(record.stem)
        let request = LocalTranscriptCleanupRequest(
            recordingDirectory: store.recordDirectoryPath(stem: record.stem),
            agent: AgentPreferences.summaryAgent()
        )
        let stem = record.stem
        Task { [weak self, backend] in
            let result = await Task.detached(priority: .utility) {
                Result { try backend.cleanTranscript(request) }
            }.value
            guard let self, case .success(let response) = result, response.ok, response.status == "complete",
                  self.selectedRecord?.stem == stem else { return }
            self.processingArtifacts = (try? self.store.processingArtifacts(stem: stem)) ?? self.processingArtifacts
        }
    }

    /// Content-based suggestions start automatically the first time an
    /// unresolved meeting is opened, so recommendations are already on the
    /// cards when the user gets there.
    func requestSpeakerSuggestionsIfNeeded(for record: MeetingRecord) {
        guard record.stage == .speakerReview, !suggestedStems.contains(record.stem) else { return }
        suggestedStems.insert(record.stem)
        // Already computed and cached (warmed at phase-one or a prior open):
        // the cache is loaded in select(); do not spend another agent call.
        guard !store.hasCachedSpeakerSuggestions(stem: record.stem) else { return }
        Task { await requestSpeakerSuggestions(quiet: true) }
    }

    /// Precomputes and caches the transcript-read speaker hints for a specific
    /// meeting as soon as its transcription finishes, so the hints are already
    /// on the cards the first time the user opens it (no "AI is reading..."
    /// wait). Independent of selection and silent on failure; a missing agent
    /// CLI simply leaves the hints to be produced lazily on open.
    func warmSpeakerSuggestions(stem: String) {
        guard !store.hasCachedSpeakerSuggestions(stem: stem),
              store.hasPhaseOneTranscript(stem: stem) else { return }
        let request = LocalSpeakerHintsRequest(
            recordingDirectory: store.recordDirectoryPath(stem: stem),
            agent: AgentPreferences.summaryAgent(),
            language: AgentPreferences.language()
        )
        Task { [weak self, backend] in
            let result = await Task.detached(priority: .utility) {
                Result { try backend.suggestSpeakers(request) }
            }.value
            guard let self,
                  case .success(let response) = result, response.ok, response.status == "complete" else { return }
            self.store.writeSpeakerSuggestions(response.suggestions ?? [], stem: stem)
            if self.selectedRecord?.stem == stem {
                self.speakerSuggestions = self.store.cachedSpeakerSuggestions(stem: stem)
            }
        }
    }

    /// Asks the selected agent for content-based speaker suggestions. The
    /// result is an in-memory proposal list only; the user still confirms
    /// each card explicitly.
    func requestSpeakerSuggestions(quiet: Bool = false) async {
        guard let record = selectedRecord, !isSuggestingSpeakers else { return }
        isSuggestingSpeakers = true
        let request = LocalSpeakerHintsRequest(
            recordingDirectory: store.recordDirectoryPath(stem: record.stem),
            agent: AgentPreferences.summaryAgent(),
            language: AgentPreferences.language()
        )
        let result = await Task.detached(priority: .utility) { [backend] in
            Result { try backend.suggestSpeakers(request) }
        }.value
        isSuggestingSpeakers = false
        switch result {
        case .success(let response) where response.ok && response.status == "complete":
            var grouped: [String: [SpeakerSuggestion]] = [:]
            for suggestion in response.suggestions ?? [] {
                grouped[suggestion.speaker, default: []].append(suggestion)
            }
            speakerSuggestions = grouped
            // Cache so this meeting opens instantly next time (and records that
            // the agent ran even when it found nothing).
            store.writeSpeakerSuggestions(response.suggestions ?? [], stem: record.stem)
            if !quiet {
                recoveryAction = grouped.isEmpty ? Loc.tr("The agent found no speaker it could support with transcript evidence.") : nil
            }
        case .success(let response):
            guard !quiet else { return }
            recoveryAction = response.errorCode == "agent_cli_missing"
                ? String(format: Loc.tr("The %@ CLI is unavailable or not signed in. Fix it in Settings, then retry the summary stage."), AgentPreferences.summaryAgent().displayName)
                : Loc.tr("Speaker suggestions were not produced. Retry after checking local diagnostics.")
        case .failure:
            guard !quiet else { return }
            recoveryAction = Loc.tr("Speaker suggestions were not produced. Retry after checking local diagnostics.")
        }
    }

    /// Optional contact email on a person profile; empty input clears it.
    func setPersonEmail(name: String, email: String) async -> Bool {
        guard guardRemoteWrite() else { return false }
        let request = LocalPersonEmailRequest(
            peoplesDirectory: store.peoplesDirectoryPath,
            name: name,
            email: email
        )
        let result = await Task.detached(priority: .utility) { [backend] in
            Result { try backend.setPersonEmail(request) }
        }.value
        if case .success = result {
            scheduleIndexRebuild()
            return true
        }
        recoveryAction = Loc.tr("The email was not saved. Check that it looks like a plain address and retry.")
        return false
    }

    func profileEmail(for person: LocalPersonProfile) -> String? {
        store.profileEmail(name: person.name)
    }

    /// Full profile merge (R7): archives the absorbed folder first, transfers
    /// history/voice/notes/aliases into the primary, then rebuilds the index
    /// with one automatic retry. Files always stay recoverable; a rebuild
    /// failure points at the Settings reindex action instead of blocking.
    func mergeProfiles(primaryName: String, absorbedName: String) async -> Bool {
        guard guardRemoteWrite() else { return false }
        do {
            _ = try store.mergeProfiles(primaryName: primaryName, absorbedName: absorbedName)
        } catch {
            recoveryAction = Loc.tr("The profiles were not merged. Both profiles are unchanged; retry after checking local storage.")
            return false
        }
        refreshLibrary()
        let storeRoot = store.storeRootPath
        let rebuilt = await Task.detached(priority: .utility) { [backend] in
            for _ in 0..<2 {
                if (try? backend.rebuildIndex(storeRoot: storeRoot))?.ok == true { return true }
            }
            return false
        }.value
        if !rebuilt {
            recoveryAction = Loc.tr("Profiles merged, but the search index could not be rebuilt. Files are intact; run Rebuild index from Settings.")
        }
        return true
    }

    /// Deletes a person from People: the profile folder is archived under
    /// peoples/archive and the name goes on the local denylist so past
    /// meeting confirmations stop resurfacing them. Meetings are untouched.
    func deletePerson(_ profile: LocalPersonProfile) async -> Bool {
        guard guardRemoteWrite() else { return false }
        do {
            _ = try store.deletePerson(named: profile.name, aliases: profile.aliases)
        } catch {
            recoveryAction = Loc.tr("The person could not be deleted. The profile is unchanged; retry after checking local storage.")
            return false
        }
        people = (try? store.listPeople(records: records)) ?? people
        scheduleIndexRebuild()
        return true
    }

    /// Removes one alias from a person profile (user-initiated from the
    /// profile detail; aliases are only ever added through confirmations).
    func removePersonAlias(name: String, alias: String) async -> Bool {
        guard guardRemoteWrite() else { return false }
        let request = LocalRemovePersonAliasRequest(
            peoplesDirectory: store.peoplesDirectoryPath,
            name: name,
            alias: alias
        )
        let result = await Task.detached(priority: .utility) { [backend] in
            Result { try backend.removePersonAlias(request) }
        }.value
        if case .success = result {
            people = (try? store.listPeople(records: records)) ?? people
            scheduleIndexRebuild()
            return true
        }
        recoveryAction = Loc.tr("The alias was not removed. Retry after checking local processing diagnostics.")
        return false
    }

    func processingArtifactsSnapshot(stem: String) throws -> MeetingProcessingArtifacts {
        try store.processingArtifacts(stem: stem)
    }

    /// A regenerated summary REPLACES the proposals the user has not decided
    /// on yet, keeping only the ones they already accepted or rejected. Two
    /// LLM runs never phrase the same person's note identically, so the old
    /// exact-`(name, note)` dedup let every "Generate summary" press stack a
    /// fresh near-duplicate proposal per person onto the undecided pile
    /// (confirmed via a real two-machine run: one meeting showed each
    /// participant's proposal twice after a re-summary). Decided notes still
    /// dedup an incoming exact match so an accepted note is not re-proposed.
    func mergedPersonNotes(existing: [PersonNoteProposal]?, proposed: [PersonNoteProposal]) -> [PersonNoteProposal] {
        var merged = (existing ?? []).filter { $0.status != .proposed }
        for proposal in proposed where !merged.contains(where: { $0.name == proposal.name && $0.note == proposal.note }) {
            merged.append(proposal)
        }
        return merged
    }

    private func updatePersonNote(in record: inout MeetingRecord, matching proposal: PersonNoteProposal, to status: PersonNoteStatus, note: String) {
        var notes = record.personNotes ?? []
        if let index = notes.firstIndex(where: { $0.id == proposal.id }) {
            notes[index].status = status
            notes[index].note = note
        }
        record.personNotes = notes
    }

    private func scheduleIndexRebuild() {
        let root = store.storeRootPath
        Task.detached(priority: .background) { [backend] in
            _ = try? backend.rebuildIndex(storeRoot: root)
        }
    }

    private struct PhaseOneAudioPaths {
        let audioPath: String
        let systemAudioPath: String?
    }

    /// Resolves which local audio file(s) belong to a record, for the legacy
    /// combined-audio detection below (D-13: the actual phase-one trigger no
    /// longer builds a request body at all - the server derives its own
    /// audio-file selection from whatever the upload archive contains). A
    /// legacy local record written before `systemAudioFile` existed adopts
    /// its canonical sibling when present, while Plaud and genuine mic-only
    /// records stay single-track.
    private func phaseOneAudioPaths(for record: MeetingRecord) -> PhaseOneAudioPaths? {
        guard let originalAudioFile = record.originalAudioFile else { return nil }
        let directory = URL(fileURLWithPath: store.recordDirectoryPath(stem: record.stem))
        let systemAudioFile: String?
        if let explicit = record.systemAudioFile {
            systemAudioFile = explicit
        } else if record.source == .local, originalAudioFile != "system-audio.m4a",
                  store.holdsRecordAudioLocally(stem: record.stem) {
            let legacy = recordDirectory(for: record).appendingPathComponent("system-audio.m4a")
            systemAudioFile = FileManager.default.fileExists(atPath: legacy.path) ? legacy.lastPathComponent : nil
        } else {
            systemAudioFile = nil
        }
        return PhaseOneAudioPaths(
            audioPath: directory.appendingPathComponent(originalAudioFile).path,
            systemAudioPath: systemAudioFile.map { directory.appendingPathComponent($0).path }
        )
    }

    private func existingAudioURL(named fileName: String?, in record: MeetingRecord) -> URL? {
        guard let fileName,
              !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/"),
              !fileName.contains("\\") else { return nil }
        let url = recordDirectory(for: record).appendingPathComponent(fileName)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) > 0,
              url.deletingLastPathComponent().resolvingSymlinksInPath()
                == recordDirectory(for: record).resolvingSymlinksInPath() else { return nil }
        return url
    }

    private func recoverableCombinedAudio(for record: MeetingRecord) -> (expected: Bool, fileName: String?) {
        let transcriptURL = recordDirectory(for: record).appendingPathComponent("transcript.raw.json")
        guard let values = try? transcriptURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let data = try? Data(contentsOf: transcriptURL),
              let provenance = try? JSONDecoder().decode(PhaseOneTranscriptProvenance.self, from: data),
              provenance.sourceFile == "combined-audio.m4a",
              let sourceFiles = provenance.sourceFiles,
              sourceFiles.count == 2,
              let paths = phaseOneAudioPaths(for: record),
              let systemAudioPath = paths.systemAudioPath else {
            return (false, nil)
        }
        let microphoneName = URL(fileURLWithPath: paths.audioPath).lastPathComponent
        let systemName = URL(fileURLWithPath: systemAudioPath).lastPathComponent
        guard Set(sourceFiles) == Set([microphoneName, systemName]) else { return (false, nil) }
        let rawSourcesExist = existingAudioURL(named: microphoneName, in: record) != nil
            && existingAudioURL(named: systemName, in: record) != nil
        guard rawSourcesExist else { return (true, nil) }
        let combined = existingAudioURL(named: "combined-audio.m4a", in: record)
        return (true, combined?.lastPathComponent)
    }

    private func synchronizeSelectedRecordAfterRecovery(_ record: MeetingRecord) {
        guard selectedRecord?.stem == record.stem else { return }
        selectedRecord = record
        processingArtifacts = (try? store.processingArtifacts(stem: record.stem)) ?? .empty
        if record.stage == .speakerReview {
            state = .speakerReview(processingArtifacts.proposals.count)
            recoveryAction = nil
        }
    }

    /// D-13's one retry path for a failed processing job: re-queues the
    /// server's already-failed phase-one job for this stem (`POST
    /// /v1/recordings/{stem}/requeue`) and resumes polling - the server
    /// re-runs it against the audio it already has, so there is nothing left
    /// for the client to re-upload or re-validate locally.
    func retrySelectedPhaseOne() async {
        guard guardRemoteWrite() else { return }
        guard var record = selectedRecord else { return }
        guard let remote = store as? RemoteMeetingStore else {
            recoveryAction = Loc.tr("Server storage is not configured. Set it up in Settings.")
            return
        }
        if remote.isRemoteConnection, remote.holdsRecordAudioLocally(stem: record.stem) {
            // Still in the outbox (never reached the server): nothing there
            // to requeue yet. The outbox sweep hands it over automatically
            // once the connection is back (R9).
            state = .failed("recording_not_transferred")
            recoveryAction = Loc.tr("This recording has not reached the server yet. It transfers automatically once the server is reachable.")
            return
        }
        record = MeetingDetailActions.retry(.transcribing, for: record)
        record.resolutions = []
        record.transcript = nil
        record.summary = nil
        record.personNotes = nil
        do {
            try store.update(record)
            try store.invalidatePhaseOneDependents(stem: record.stem)
        } catch {
            record.stage = .failed
            record.lastErrorCode = "phase_one_retry_preparation_failed"
            try? store.update(record)
            replace(record)
            selectedRecord = record
            processingArtifacts = .empty
            state = .failed("phase_one_retry_preparation_failed")
            recoveryAction = Loc.tr("The previous speaker-review artifacts could not be cleared safely. Check this meeting folder, then retry local processing.")
            return
        }
        refreshedCandidateStems.remove(record.stem)
        suggestedStems.remove(record.stem)
        cleanedTranscriptStems.remove(record.stem)
        speakerSuggestions = [:]
        replace(record)
        selectedRecord = record
        processingArtifacts = .empty
        state = .processing
        do {
            try await remote.requeueProcessing(stem: record.stem)
        } catch {
            failProcessing(record, error: error)
            return
        }
        beginPollingProcessing(stem: record.stem)
    }

    /// A record whose outbox copy holds the audio is either still pending
    /// handoff, or - after a successful handoff - has had its outbox audio
    /// already cleaned up (`deleteOutboxAudioIfPhaseOneComplete`); this marker
    /// path never actually exists on disk, it only names the check that
    /// distinguishes the two without adding new persisted state: a record is
    /// "still pending" exactly when its outbox directory still holds the
    /// original audio *and* the cache has no committed copy yet.
    private func outboxAudioMissingMarkerPath(for record: MeetingRecord) -> String { "" }

    /// Diarization-only rerun with a user-supplied speaker count, offered on
    /// the speaker-review screen while no speaker has been confirmed yet.
    /// The transcript text is replayed unchanged; only the speaker split is
    /// redone (NME-SC pinned to the given count). Confirmed reviews are never
    /// re-split - the entry point disappears once naming starts, because new
    /// labels would orphan every existing confirmation.
    func reclusterSpeakers(count: Int) async {
        guard guardRemoteWrite() else { return }
        guard count >= 1, !isReclustering,
              var record = selectedRecord,
              record.stage == .speakerReview,
              record.resolutions.isEmpty,
              let audioURL = sourceAudioURL(for: record) else { return }
        let request = LocalReclusterRequest(
            recordingDirectory: store.recordDirectoryPath(stem: record.stem),
            audioPath: audioURL.path,
            numSpeakers: count
        )
        isReclustering = true
        let result = await Task.detached(priority: .utility) { [backend] in
            Result { try backend.recluster(request) }
        }.value
        isReclustering = false
        switch result {
        case .success:
            // Every artifact keyed by the old speaker labels is stale now.
            refreshedCandidateStems.remove(record.stem)
            suggestedStems.remove(record.stem)
            speakerSuggestions = [:]
            // recluster rewrote the transcript with a new segmentation, so the
            // index-keyed cleanup overlay no longer aligns. Drop it and clear
            // the run-once guard so the reselect below re-runs cleanup against
            // the new transcript instead of overlaying stale corrections.
            cleanedTranscriptStems.remove(record.stem)
            try? store.invalidateCleanupOverlay(stem: record.stem)
            record.hints.numSpeakers = count
            record.lastErrorCode = nil
            do {
                try store.update(record)
                activeRecord = record.stem == activeRecord?.stem ? record : activeRecord
                replace(record)
                // Re-enter through the normal selection path so candidate
                // refresh and speaker suggestions re-run for the new labels.
                select(record)
                recoveryAction = nil
                scheduleIndexRebuild()
            } catch {
                state = .failed("recluster_save_failed")
                recoveryAction = Loc.tr("The re-split speakers could not be loaded. Reopen this meeting.")
            }
        case .failure:
            state = .failed("recluster_failed")
            recoveryAction = Loc.tr("The speakers were not re-split. The current review is unchanged; retry after checking local processing diagnostics.")
        }
    }

    func saveCorrections(title: String, transcript: [TranscriptSegment]?, summary: StructuredSummary?) {
        guard let record = selectedRecord else { return }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrections = MeetingCorrections(
            title: cleaned.isEmpty ? nil : cleaned,
            transcript: transcript,
            summary: summary
        )
        let updated = MeetingDetailActions.applying(corrections, to: record)
        do {
            try store.update(updated)
            replace(updated)
            selectedRecord = updated
        } catch {
            state = .failed("meeting_correction_save_failed")
            recoveryAction = Loc.tr("The correction was not saved. Check local storage and try again.")
        }
    }

    func sourceAudioURL(for record: MeetingRecord) -> URL? {
        existingAudioURL(named: record.processedAudioFile, in: record)
            ?? existingAudioURL(named: record.originalAudioFile, in: record)
    }

    /// The audio URL AVAudioPlayer can decode right now: the original for
    /// native formats, the cached transcode for ogg/opus records. Nil while a
    /// transcode is still pending (see preparePlayableAudio).
    func playbackAudioURL(for record: MeetingRecord) -> URL? {
        guard let original = sourceAudioURL(for: record) else { return nil }
        return PlayableAudioCache.existingPlayableURL(for: original)
    }

    /// Resolves (and if necessary produces, via a one-time local ffmpeg
    /// transcode) the playable audio for a record. `isPreparingPlayback` is
    /// published so the player UI can show the conversion state.
    @Published private(set) var isPreparingPlayback = false

    func preparePlayableAudio(for record: MeetingRecord) async -> URL? {
        if sourceAudioURL(for: record) == nil {
            // Audio is excluded from the periodic cache sync (R7); fetch the
            // specific file this record needs on demand. A disconnected mini
            // simply leaves both fetches unsatisfied and sourceAudioURL(for:)
            // keeps returning nil, which the player already treats as
            // "unavailable" rather than an error (R4/AC5).
            let localDirectory = store.recordDirectoryURL(stem: record.stem)
            for fileName in [record.processedAudioFile, record.originalAudioFile].compactMap({ $0 }) {
                await audioFetcher.ensureAvailable(
                    localURL: localDirectory.appendingPathComponent(fileName),
                    stem: record.stem,
                    filename: fileName
                )
            }
        }
        guard let original = sourceAudioURL(for: record) else { return nil }
        if let ready = PlayableAudioCache.existingPlayableURL(for: original) { return ready }
        isPreparingPlayback = true
        defer { isPreparingPlayback = false }
        let prepared = await PlayableAudioCache.preparePlayableURL(for: original)
        if prepared != nil, selectedRecord?.stem == record.stem {
            // Excerpt buttons key off playbackAudioURL; nudge observers.
            objectWillChange.send()
        }
        return prepared
    }

    private func startNow() async {
        Self.recordingLogger.notice("recording_start_requested")
        state = .checkingPermissions
        recoveryAction = nil
        let permission = await capture.permissionState()
        guard permission == .ready else {
            Self.recordingLogger.notice("recording_start_blocked")
            state = .failed("recording_permission_required")
            recoveryAction = permission == .microphoneDenied
                ? Loc.tr("Allow Microphone access in System Settings, then try again.")
                : Loc.tr("Allow Screen Recording access in System Settings, then try again.")
            return
        }
        do {
            let effectiveHints = plannedHints(basedOn: session.hints)
            let draft = MeetingDraft(
                stem: Self.makeStem(),
                source: .local,
                title: effectiveHints.topic ?? Loc.tr("Untitled local meeting"),
                hints: effectiveHints
            )
            let record = try store.createRecord(draft)
            try store.commit(record)
            do {
                _ = try await session.startNow(in: recordDirectory(for: record))
            } catch {
                try? store.quarantine(stem: record.stem, reason: "recording_start_failed")
                refreshLibrary()
                throw error
            }
            activeRecord = record
            replace(record)
            selectedRecord = record
            processingArtifacts = .empty
            state = .recording
            recordingStartedAt = Date()
            recoveryAction = nil
            // The plan applied to this recording; clear it so the next one
            // starts from a clean slate instead of inheriting a stale count.
            plannedSpeakerCount = SpeakerPlan.defaultCount
            plannedParticipants = []
            Self.recordingLogger.notice("recording_start_succeeded")
        } catch {
            Self.recordingLogger.error("recording_start_failed code=\(self.recordingStartErrorCode(for: error), privacy: .public)")
            state = .failed("recording_start_failed")
            recoveryAction = recordingStartRecoveryMessage(for: error)
        }
    }

    private func recordingStartErrorCode(for error: Error) -> String {
        if let localError = error as? LocalRecordingError {
            switch localError {
            case .microphonePermissionDenied: return "microphone_permission"
            case .screenRecordingPermissionDenied: return "screen_recording_permission"
            case .noDisplayAvailable: return "no_display"
            case .systemAudioWriterFailed: return "system_audio_writer"
            case .alreadyRecording: return "already_recording"
            case .notRecording: return "not_recording"
            }
        }
        if error is RecordingSessionError { return "recording_session" }
        return "native_capture"
    }

    private func recordingStartRecoveryMessage(for error: Error) -> String {
        if let localError = error as? LocalRecordingError {
            switch localError {
            case .microphonePermissionDenied:
                return Loc.tr("Allow Microphone access in System Settings, then try again.")
            case .screenRecordingPermissionDenied:
                return Loc.tr("Allow Screen Recording access in System Settings, then try again to capture system audio.")
            case .noDisplayAvailable:
                return Loc.tr("Connect or enable a display, then try recording again.")
            case .systemAudioWriterFailed:
                return Loc.tr("System audio could not start safely. Keep local files if any were captured, then retry.")
            case .alreadyRecording, .notRecording:
                break
            }
        }
        return Loc.tr("Keep local files if any were captured, then retry recording.")
    }

    private func stopAndProcess() async {
        guard await stopCaptureKeepingDecision() != nil else { return }
        processStoppedRecording()
    }

    /// Stops capture and persists the audio file names without starting the
    /// pipeline, so the caller can still decide the recording's fate (the
    /// detection flow holds this decision for the 5-minute cutoff). Returns
    /// the stopped record, or nil when stopping failed.
    private func stopCaptureKeepingDecision() async -> MeetingRecord? {
        recordingStartedAt = nil
        do {
            let files = try await session.stop()
            guard var record = activeRecord else {
                throw LocalProcessingCommandError.failed
            }
            record.hints = session.hints
            record.originalAudioFile = files.microphone.lastPathComponent
            record.systemAudioFile = files.systemAudio.lastPathComponent
            record.processedAudioFile = nil
            try store.update(record)
            activeRecord = record
            replace(record)
            state = .ready
            return record
        } catch {
            state = .failed("recording_stop_failed")
            recoveryAction = session.recoveryAction ?? Loc.tr("Keep the captured local audio and retry stopping the recording.")
            return nil
        }
    }

    /// Uploads the already-stopped active recording and starts polling (D-13:
    /// commit auto-enqueues phase-one server-side; this client only starts
    /// and watches the job).
    private func processStoppedRecording() {
        guard var record = activeRecord, record.originalAudioFile != nil else { return }
        record.stage = .transcribing
        try? store.update(record)
        activeRecord = record
        replace(record)
        state = .processing
        let processing = record
        Task { [weak self] in
            guard let self, let remote = self.store as? RemoteMeetingStore else { return }
            do {
                try await remote.triggerProcessing(stem: processing.stem)
            } catch {
                self.failProcessing(processing, error: error)
                return
            }
            self.beginPollingProcessing(stem: processing.stem)
        }
    }

    // MARK: External sync entry points

    /// D-14: Plaud imports go through the exact same outbox+upload+commit
    /// path as a manually stopped recording, so the server sees every input
    /// as an identical upload regardless of source.
    func importExternalRecording(_ record: MeetingRecord, movingAudioFrom audioURL: URL) throws {
        try store.commitImported(record, movingAudioFrom: audioURL)
    }

    /// The local root External Sync needs only for its own checkpoint
    /// bookkeeping (`ExternalSyncCheckpointStore`) - never for a direct
    /// canonical-store write, which now always goes through
    /// `importExternalRecording` above regardless of local/remote mode.
    /// Deliberately `localRootURL`, not `storeRootPath`: in remote mode the
    /// latter is the server's own filesystem path (confirmed: writing the
    /// checkpoint there on the client Mac always failed with
    /// `state_persistence_failed`, since that path belongs to a different
    /// machine and is typically absent or unwritable here).
    var externalSyncStoreRootURL: URL? {
        store.isConfigured ? store.localRootURL : nil
    }

    /// Registers a freshly committed external import in the visible library.
    /// A re-synced or adopted record that already carries a transcript is
    /// promoted straight to speaker review. A genuinely new import that still
    /// needs transcription is held at `.captured` instead of transcribing
    /// immediately, so the user can set the expected speaker count first (the
    /// only reliable guard against diarization over-segmentation on
    /// low-quality provider audio). `startHeldImport` releases the hold.
    /// Selection stays where the user left it.
    func noteExternalImport(stem: String) {
        guard let record = try? store.load(stem: stem) else { return }
        replace(record)
        if store.hasCompletePhaseOneReviewArtifacts(stem: stem) {
            processImportedMeeting(stem: stem)
        }
    }

    /// True while an imported meeting is waiting for the user's speaker-count
    /// plan before transcription begins.
    func isHeldImport(_ record: MeetingRecord) -> Bool {
        record.source != .local
            && record.stage == .captured
            && !store.hasCompletePhaseOneReviewArtifacts(stem: record.stem)
    }

    /// Releases a held import: records the optional speaker-count and
    /// participant plan on the meeting, then starts the normal local pipeline.
    /// A `speakerCount` of 0 leaves diarization on auto (the user skipped).
    func startHeldImport(stem: String, speakerCount: Int, participants: [String]) {
        guard var record = try? store.load(stem: stem), isHeldImport(record) else { return }
        var hints = record.hints
        if speakerCount > 0 { hints.numSpeakers = speakerCount }
        for name in participants {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !hints.participants.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { continue }
            hints.participants.append(trimmed)
        }
        record.hints = hints
        try? store.update(record)
        replace(record)
        if selectedRecord?.stem == stem { selectedRecord = record }
        processImportedMeeting(stem: stem)
    }

    /// Starts the normal pipeline (upload/trigger → poll → speaker review →
    /// summary) for a meeting imported by external sync. Unlike the manual
    /// recording path this never touches the active recording, selection, or
    /// global workspace state, so a background import cannot hijack the UI.
    /// The server's queue serializes actual work; this only avoids starting a
    /// second poll loop for the same stem.
    func processImportedMeeting(stem: String) {
        guard !pollingStems.contains(stem) else { return }
        guard let record = try? store.load(stem: stem), record.originalAudioFile != nil else { return }
        // Idempotent guard: a record that already carries a phase-one
        // transcript must never be transcribed again (an interrupted import,
        // an adopted legacy record, or a re-synced file). Promote it straight
        // to speaker review instead of respawning a heavy subprocess.
        if store.hasCompletePhaseOneReviewArtifacts(stem: stem) {
            var adopted = record
            var changed = false
            let combinedRecovery = recoverableCombinedAudio(for: adopted)
            if let recovered = combinedRecovery.fileName, adopted.processedAudioFile != recovered {
                adopted.processedAudioFile = recovered
                changed = true
            } else if combinedRecovery.expected && combinedRecovery.fileName == nil && !adopted.stage.isTerminal {
                adopted.stage = .failed
                adopted.lastErrorCode = "combined_audio_unavailable"
                changed = true
                if selectedRecord?.stem == stem {
                    state = .failed("combined_audio_unavailable")
                    recoveryAction = Loc.tr("The combined playback audio is missing. Restore both captured tracks and retry local processing.")
                }
                try? store.update(adopted)
                replace(adopted)
                synchronizeSelectedRecordAfterRecovery(adopted)
                return
            }
            if !adopted.stage.isTerminal, adopted.stage != .speakerReview, adopted.stage != .summarizing {
                adopted.stage = .speakerReview
                adopted.completedStages = [.captured, .transcribing, .speakerReview]
                changed = true
            }
            if changed {
                try? store.update(adopted)
                replace(adopted)
                synchronizeSelectedRecordAfterRecovery(adopted)
            }
            return
        }
        var queued = record
        queued.stage = .transcribing
        try? store.update(queued)
        replace(queued)
        Task { [weak self] in
            guard let self, let remote = self.store as? RemoteMeetingStore else { return }
            do {
                try await remote.triggerProcessing(stem: stem)
            } catch {
                var failed = queued
                let failure = self.processingFailureDetails(error)
                failed.stage = .failed
                failed.lastErrorCode = failure.code
                try? self.store.update(failed)
                self.replace(failed)
                if self.selectedRecord?.stem == stem {
                    self.state = .failed(failure.code)
                    self.recoveryAction = failure.nextAction
                }
                return
            }
            self.beginPollingProcessing(stem: stem)
        }
    }


    // MARK: Detection-driven recording entry points

    /// Starts a detected-meeting recording through the exact same path as the
    /// manual Record button. Returns false when capture could not start so
    /// the detection session can fall back to prompting.
    func detectionStartRecording() async -> Bool {
        guard !isRecording, !isCaptureStartPending else { return false }
        await startNow()
        return isRecording
    }

    /// Stops a detected recording without deciding its fate; the 5-minute
    /// cutoff decision (process or discard) follows separately.
    func detectionStopRecording() async -> Bool {
        guard isRecording else { return false }
        return await stopCaptureKeepingDecision() != nil
    }

    /// The stopped detected recording met the cutoff or the user chose
    /// [그래도 보관]: run the normal pipeline.
    func detectionProcessStoppedRecording() {
        processStoppedRecording()
    }

    /// Directory of the currently active recording's record, where the
    /// participant capture pipeline writes participants.json.
    func activeRecordingDirectory() -> URL? {
        activeRecord.map { recordDirectory(for: $0) }
    }

    /// The stopped detected recording is below the cutoff and was discarded
    /// ([버리기] or the no-response timeout): its folder is removed so it
    /// never appears in the meeting log. Irreversible by approved contract.
    func detectionDiscardStoppedRecording() {
        guard let record = activeRecord else { return }
        Self.recordingLogger.notice("detected_recording_discarded stem=\(record.stem, privacy: .public)")
        try? FileManager.default.removeItem(at: recordDirectory(for: record))
        activeRecord = nil
        state = .ready
        recoveryAction = nil
        refreshLibrary()
    }

    private func saveSummaryFailure(_ record: MeetingRecord, code: String) {
        var updated = record
        updated.stage = .partial
        updated.lastErrorCode = code
        updated.completedStages = [.captured, .transcribing, .speakerReview]
        do {
            try store.update(updated)
            replace(updated)
            selectedRecord = updated
        } catch {
            state = .failed("summary_failure_save_failed")
            recoveryAction = Loc.tr("The local summary error could not be saved. Check local storage and retry.")
            return
        }
        state = .ready
        switch code {
        case "agent_cli_missing", "launch_failed", "summary_launch_failed", "nonzero_exit":
            let agent = AgentPreferences.summaryAgent().displayName
            recoveryAction = String(format: Loc.tr("The %@ CLI is unavailable or not signed in. Fix it in Settings, then retry the summary stage."), agent)
        default:
            recoveryAction = Loc.tr("No summary was saved. Review local diagnostics and retry the summary stage.")
        }
    }

    private func failProcessing(_ record: MeetingRecord, error: Error? = nil) {
        var updated = record
        updated.stage = .failed
        let failure = processingFailureDetails(error)
        updated.lastErrorCode = failure.code
        try? store.update(updated)
        activeRecord = updated
        replace(updated)
        selectedRecord = updated
        state = .failed(failure.code)
        recoveryAction = failure.nextAction
    }

    private func processingFailureDetails(_ error: Error?) -> (code: String, nextAction: String) {
        if let commandError = error as? LocalProcessingCommandError,
           case .backend(let backendCode, let backendNextAction) = commandError {
            return (backendCode, backendNextAction)
        }
        return (
            "local_processing_failed",
            Loc.tr("Local processing failed without uploading meeting data. Check local models and retry.")
        )
    }

    private func recordDirectory(forStem stem: String) -> URL {
        store.recordDirectoryURL(stem: stem)
    }

    private func recordDirectory(for record: MeetingRecord) -> URL {
        store.recordDirectoryURL(stem: record.stem)
    }

    private func select(_ record: MeetingRecord) {
        if selectedRecord?.stem != record.stem {
            // Show any hints already computed for this meeting immediately, so
            // opening it never starts behind an empty "AI is reading..." wait.
            speakerSuggestions = store.cachedSpeakerSuggestions(stem: record.stem)
            // `state`/`recoveryAction` are set by the last action attempted
            // (delete, summary retry, speaker resolution, a disconnected-
            // server write guard, ...), always against whichever record was
            // selected at the time - never scoped to a stem. Left uncleared,
            // a failure on one meeting kept showing as "Recording needs
            // attention" (and the inline recovery banner in the overview
            // tab, which renders `recoveryAction` unconditionally) on every
            // other meeting the user opened afterward, including already-
            // complete ones with nothing wrong (confirmed via a real
            // two-machine test: the banner read identically across
            // unrelated meetings). `recoveryAction` always clears; `state`
            // only resets from `.failed` - `.recording`/`.processing` are
            // genuinely global and must survive a selection change.
            recoveryAction = nil
            if case .failed = state {
                state = .ready
            }
        }
        selectedRecord = record
        processingArtifacts = (try? store.processingArtifacts(stem: record.stem)) ?? .empty
        refreshCandidatesIfNeeded(for: record)
        requestSpeakerSuggestionsIfNeeded(for: record)
        requestTranscriptCleanupIfNeeded(for: record)
    }

    private func replace(_ record: MeetingRecord) {
        if let index = records.firstIndex(where: { $0.stem == record.stem }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        records.sort { $0.createdAt > $1.createdAt }
    }

    private static func makeStem(now: Date = .now) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "local-" + formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
    }

    private static let meetingDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
