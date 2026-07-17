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

/// The narrow process boundary the workspace talks to. The production
/// backend spawns the fixed local Python modules; tests substitute an
/// in-memory backend so pipeline behavior is regression-tested without
/// spawning processes.
protocol LocalProcessingBackend: Sendable {
    func runPhaseOne(_ request: LocalProcessingRequest) throws -> LocalProcessingResult
    func applyResolutions(_ request: LocalResolutionProcessingRequest) throws -> LocalProcessingResult
    func appendPersonNote(_ request: LocalPersonNoteRequest) throws -> LocalProcessingResult
    func refreshCandidates(_ request: LocalRefreshCandidatesRequest) throws -> LocalProcessingResult
    func setPersonEmail(_ request: LocalPersonEmailRequest) throws -> LocalProcessingResult
    func removePersonAlias(_ request: LocalRemovePersonAliasRequest) throws -> LocalProcessingResult
    func runSummary(_ request: LocalSummaryRequest) throws -> LocalSummaryResult
    func suggestSpeakers(_ request: LocalSpeakerHintsRequest) throws -> LocalSpeakerHintsResult
    func cleanTranscript(_ request: LocalTranscriptCleanupRequest) throws -> LocalTranscriptCleanupResult
    func rebuildIndex(storeRoot: String) throws -> LocalIndexResult
}

struct SystemProcessingBackend: LocalProcessingBackend {
    func runPhaseOne(_ request: LocalProcessingRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.runPhaseOne(request)
    }

    func applyResolutions(_ request: LocalResolutionProcessingRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.applyResolutions(request)
    }

    func appendPersonNote(_ request: LocalPersonNoteRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.appendPersonNote(request)
    }

    func refreshCandidates(_ request: LocalRefreshCandidatesRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.refreshCandidates(request)
    }

    func setPersonEmail(_ request: LocalPersonEmailRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.setPersonEmail(request)
    }

    func removePersonAlias(_ request: LocalRemovePersonAliasRequest) throws -> LocalProcessingResult {
        try LocalProcessingProcessRunner.removePersonAlias(request)
    }

    func runSummary(_ request: LocalSummaryRequest) throws -> LocalSummaryResult {
        try LocalSummaryProcessRunner.run(request)
    }

    func suggestSpeakers(_ request: LocalSpeakerHintsRequest) throws -> LocalSpeakerHintsResult {
        try LocalSpeakerHintsProcessRunner.run(request)
    }

    func cleanTranscript(_ request: LocalTranscriptCleanupRequest) throws -> LocalTranscriptCleanupResult {
        try LocalTranscriptCleanupProcessRunner.run(request)
    }

    func rebuildIndex(storeRoot: String) throws -> LocalIndexResult {
        try LocalIndexProcessRunner.rebuild(storeRoot: storeRoot)
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
    @Published private(set) var isRequestingSummary = false
    @Published private(set) var speakerSuggestions: [String: [SpeakerSuggestion]] = [:]
    @Published private(set) var isSuggestingSpeakers = false

    private let store: MeetingStore
    private let capture: any RecordingCapture
    private let session: RecordingSessionController
    private let backend: any LocalProcessingBackend
    private let notifier: any UserNotifying
    private var activeRecord: MeetingRecord?
    private var resumedSummaryStems: Set<String> = []
    private var activeProcessingStems: Set<String> = []
    private var importedProcessingChain: Task<Void, Never>?
    private var refreshedCandidateStems: Set<String> = []
    private var suggestedStems: Set<String> = []
    private var cleanedTranscriptStems: Set<String> = []

    init(store: MeetingStore? = nil, capture: any RecordingCapture = LocalRecordingCoordinator(), backend: any LocalProcessingBackend = SystemProcessingBackend(), notifier: any UserNotifying = SystemUserNotifier()) {
        self.store = store ?? StorageRootConfiguration().makeStore()
        self.capture = capture
        self.backend = backend
        self.notifier = notifier
        session = RecordingSessionController(capture: capture)
        // Do not create the default store merely by opening the app. This keeps
        // a denied first recording attempt side-effect free while still showing
        // an already-configured library immediately on later launches.
        if FileManager.default.fileExists(atPath: self.store.rootURL.path) {
            refreshLibrary()
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
    }

    func select(stem: String) {
        guard let record = records.first(where: { $0.stem == stem }) else { return }
        select(record)
    }

    func applyResolution(speaker: String, action: SpeakerResolutionAction, personName: String? = nil, alias: String? = nil) async {
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
            recordingDirectory: recordDirectory(for: record).path,
            peoplesDirectory: store.rootURL.appendingPathComponent("Plaud/peoples", isDirectory: true).path,
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

    /// Runs the automatic summary and title step for a record whose speakers
    /// are all resolved. Also serves as the manual retry entry point after a
    /// failed summary stage.
    func runSummary(for target: MeetingRecord? = nil) async {
        guard var record = target ?? selectedRecord else { return }
        let artifacts = (try? store.processingArtifacts(stem: record.stem)) ?? .empty
        guard !artifacts.transcript.isEmpty else {
            recoveryAction = Loc.tr("Finish local transcription before the summary step can run.")
            return
        }
        let allResolved = artifacts.proposals.allSatisfy { proposal in
            record.resolutions.contains { $0.speaker == proposal.speaker }
        }
        guard allResolved else {
            recoveryAction = Loc.tr("Confirm or skip every speaker card to start the automatic summary.")
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
        let request = LocalSummaryRequest(
            recordingDirectory: recordDirectory(for: record).path,
            agent: AgentPreferences.summaryAgent(),
            language: AgentPreferences.language(),
            meetingDate: LocalSummaryRequest.localMeetingDate(for: record.createdAt)
        )
        let result = await Task.detached(priority: .utility) { [backend] in
            Result { try backend.runSummary(request) }
        }.value
        isRequestingSummary = false

        switch result {
        case .success(let response) where response.ok && response.status == "complete":
            do {
                guard let artifact = try store.storedSummaryArtifact(stem: record.stem) else {
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
                if selectedRecord?.stem == record.stem { selectedRecord = record }
                state = .ready
                recoveryAction = nil
                scheduleIndexRebuild()
                postCalendarCandidateNotification(for: record)
            } catch {
                saveSummaryFailure(record, code: "summary_artifact_invalid")
            }
        case .success(let response):
            saveSummaryFailure(record, code: response.errorCode ?? "summary_unavailable")
        case .failure:
            saveSummaryFailure(record, code: "summary_launch_failed")
        }
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

    /// Resumes records interrupted mid-summary by a quit or crash: the stage
    /// journal (meeting.json) says summarizing but no terminal state was
    /// reached. Earlier stages keep their retry buttons instead of silently
    /// re-running heavy local transcription.
    func resumeInterruptedSummaries() async {
        let interrupted = records.filter { $0.stage == .summarizing }
        for record in interrupted where !resumedSummaryStems.contains(record.stem) {
            resumedSummaryStems.insert(record.stem)
            await runSummary(for: record)
        }
    }

    func acceptPersonNote(_ proposal: PersonNoteProposal, editedNote: String? = nil) async {
        guard var record = selectedRecord else { return }
        let noteText = (editedNote ?? proposal.note).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !noteText.isEmpty else { return }
        let request = LocalPersonNoteRequest(
            recordingDirectory: recordDirectory(for: record).path,
            peoplesDirectory: store.rootURL.appendingPathComponent("Plaud/peoples", isDirectory: true).path,
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
        let root = store.rootURL.path
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
            recordingDirectory: recordDirectory(for: record).path,
            peoplesDirectory: store.rootURL.appendingPathComponent("Plaud/peoples", isDirectory: true).path
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
            recordingDirectory: recordDirectory(for: record).path,
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
            recordingDirectory: recordDirectory(forStem: stem).path,
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
            recordingDirectory: recordDirectory(for: record).path,
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
        let request = LocalPersonEmailRequest(
            peoplesDirectory: store.rootURL.appendingPathComponent("Plaud/peoples", isDirectory: true).path,
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
        do {
            _ = try store.mergeProfiles(primaryName: primaryName, absorbedName: absorbedName)
        } catch {
            recoveryAction = Loc.tr("The profiles were not merged. Both profiles are unchanged; retry after checking local storage.")
            return false
        }
        refreshLibrary()
        let storeRoot = store.rootURL.path
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
        let request = LocalRemovePersonAliasRequest(
            peoplesDirectory: store.rootURL.appendingPathComponent("Plaud/peoples", isDirectory: true).path,
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

    private func mergedPersonNotes(existing: [PersonNoteProposal]?, proposed: [PersonNoteProposal]) -> [PersonNoteProposal] {
        var merged = existing ?? []
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
        let root = store.rootURL.path
        Task.detached(priority: .background) { [backend] in
            _ = try? backend.rebuildIndex(storeRoot: root)
        }
    }

    func retrySelectedPhaseOne() async {
        guard var record = selectedRecord,
              let originalAudioFile = record.originalAudioFile else { return }
        let audioURL = recordDirectory(for: record).appendingPathComponent(originalAudioFile)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            state = .failed("recording_source_missing")
            recoveryAction = Loc.tr("The original local audio is unavailable, so this meeting cannot be reprocessed.")
            return
        }
        record = MeetingDetailActions.retry(.transcribing, for: record)
        try? store.update(record)
        replace(record)
        selectedRecord = record
        state = .processing
        let request = LocalProcessingRequest(recordingDirectory: recordDirectory(for: record).path, audioPath: audioURL.path, hints: LocalProcessingHints(record.hints))
        let result = await Task.detached(priority: .utility) { [backend] in
            Result { try backend.runPhaseOne(request) }
        }.value
        switch result {
        case .success(let response):
            finishProcessing(record, speakerCount: response.speakerCount ?? 0)
        case .failure:
            failProcessing(record)
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
        guard let originalAudioFile = record.originalAudioFile else { return nil }
        let url = recordDirectory(for: record).appendingPathComponent(originalAudioFile)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
            let draft = MeetingDraft(
                stem: Self.makeStem(),
                source: .local,
                title: session.hints.topic ?? Loc.tr("Untitled local meeting"),
                hints: session.hints
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

    /// Queues the already-stopped active recording into the local pipeline.
    private func processStoppedRecording() {
        guard var record = activeRecord, let audioFile = record.originalAudioFile else { return }
        // Manual recordings skip the import queue and transcribe immediately,
        // so the visible stage goes straight to "Transcribing" instead of
        // sitting on a stale "waiting" badge while the subprocess runs.
        record.stage = .transcribing
        try? store.update(record)
        activeRecord = record
        replace(record)
        state = .processing
        activeProcessingStems.insert(record.stem)
        let request = LocalProcessingRequest(
            recordingDirectory: recordDirectory(for: record).path,
            audioPath: recordDirectory(for: record).appendingPathComponent(audioFile).path,
            hints: LocalProcessingHints(record.hints)
        )
        let processing = record
        Task { [weak self, backend] in
            let result = await Task.detached(priority: .utility) {
                Result { try backend.runPhaseOne(request) }
            }.value
            guard let self else { return }
            self.activeProcessingStems.remove(processing.stem)
            switch result {
            case .success(let response):
                self.finishProcessing(processing, speakerCount: response.speakerCount ?? 0)
            case .failure:
                self.failProcessing(processing)
            }
        }
    }

    // MARK: External sync entry points

    /// The canonical store this workspace reads and writes; external sync
    /// commits imported recordings through the same store contract.
    var meetingStore: MeetingStore { store }

    /// Registers a freshly committed external import in the visible library
    /// and starts its local pipeline. Selection stays where the user left it.
    func noteExternalImport(stem: String) {
        guard let record = try? store.load(stem: stem) else { return }
        replace(record)
        processImportedMeeting(stem: stem)
    }

    /// Starts the normal local pipeline (transcribe → speaker review →
    /// summary) for a meeting imported by external sync. Unlike the manual
    /// recording path this never touches the active recording, selection, or
    /// global workspace state, so a background import cannot hijack the UI.
    /// Imported meetings process one at a time: a sync batch must not spawn
    /// one heavy transcription subprocess per file.
    func processImportedMeeting(stem: String) {
        guard !activeProcessingStems.contains(stem) else { return }
        guard let record = try? store.load(stem: stem), let audioFile = record.originalAudioFile else { return }
        // Idempotent guard: a record that already carries a phase-one
        // transcript must never be transcribed again (an interrupted import,
        // an adopted legacy record, or a re-synced file). Promote it straight
        // to speaker review instead of respawning a heavy subprocess.
        if store.hasPhaseOneTranscript(stem: stem) {
            var adopted = record
            if !adopted.stage.isTerminal, adopted.stage != .speakerReview, adopted.stage != .summarizing {
                adopted.stage = .speakerReview
                adopted.completedStages = [.captured, .transcribing, .speakerReview]
                try? store.update(adopted)
                replace(adopted)
            }
            return
        }
        activeProcessingStems.insert(stem)
        var queued = record
        queued.stage = .queued
        try? store.update(queued)
        replace(queued)
        let request = LocalProcessingRequest(
            recordingDirectory: recordDirectory(for: queued).path,
            audioPath: recordDirectory(for: queued).appendingPathComponent(audioFile).path,
            hints: LocalProcessingHints(queued.hints)
        )
        let stem = queued.stem
        let previous = importedProcessingChain
        importedProcessingChain = Task { [weak self, backend] in
            await previous?.value
            // Persist the transcribing stage when this record's turn actually
            // starts, so the UI shows the animated "Transcribing" state instead
            // of a stale "queued/waiting" while the subprocess runs.
            if let self, var running = try? self.store.load(stem: stem), running.stage == .queued {
                running.stage = .transcribing
                try? self.store.update(running)
                self.replace(running)
            }
            let result = await Task.detached(priority: .utility) {
                Result { try backend.runPhaseOne(request) }
            }.value
            guard let self else { return }
            self.activeProcessingStems.remove(stem)
            guard var updated = try? self.store.load(stem: stem) else { return }
            switch result {
            case .success:
                updated.stage = .speakerReview
                updated.completedStages = [.captured, .transcribing, .speakerReview]
                updated.lastErrorCode = nil
            case .failure:
                updated.stage = .failed
                updated.lastErrorCode = "local_processing_failed"
            }
            try? self.store.update(updated)
            self.replace(updated)
            if self.selectedRecord?.stem == stem {
                self.selectedRecord = updated
                self.processingArtifacts = (try? self.store.processingArtifacts(stem: stem)) ?? .empty
            }
            if updated.stage == .speakerReview {
                self.warmSpeakerSuggestions(stem: stem)
            }
            self.scheduleIndexRebuild()
        }
    }

    /// Imported meetings interrupted mid-transcription by a quit or crash
    /// stay in the queued stage; restart them once per session so external
    /// sync's automatic processing promise survives an app restart (R6).
    func resumeInterruptedImportedProcessing() {
        // Records left mid-flight by a quit or crash: queued (never started) or
        // transcribing (started, no terminal write). processImportedMeeting is
        // idempotent, so a record that already has a transcript is promoted
        // instead of re-transcribed.
        let interrupted = records.filter { $0.source != .local && ($0.stage == .queued || $0.stage == .transcribing) }
        for record in interrupted {
            processImportedMeeting(stem: record.stem)
        }
    }

    /// Local recordings left in the pre-transcription stage (`captured`) by a
    /// crash or an older build never auto-started their pipeline. On launch,
    /// promote the ones that already have a transcript and enqueue the ones
    /// that genuinely still need transcription, one at a time.
    func resumeUnprocessedLocalRecordings() {
        // transcribing is included for a crash mid-transcription; the active
        // stems guard keeps a live in-process run from being restarted when
        // the window reopens mid-flight.
        let pending = records.filter { $0.source == .local && ($0.stage == .captured || $0.stage == .queued || $0.stage == .transcribing) }
        for record in pending {
            processImportedMeeting(stem: record.stem)
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

    private func finishProcessing(_ record: MeetingRecord, speakerCount: Int) {
        var updated = record
        updated.stage = .speakerReview
        updated.completedStages = [.captured, .transcribing, .speakerReview]
        try? store.update(updated)
        activeRecord = updated
        replace(updated)
        selectedRecord = updated
        processingArtifacts = (try? store.processingArtifacts(stem: updated.stem)) ?? .empty
        state = .speakerReview(speakerCount)
        recoveryAction = nil
        // Warm the transcript-read hints now so they are already on the cards
        // the first time this freshly transcribed meeting is opened.
        warmSpeakerSuggestions(stem: updated.stem)
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

    private func failProcessing(_ record: MeetingRecord) {
        var updated = record
        updated.stage = .failed
        updated.lastErrorCode = "local_processing_failed"
        try? store.update(updated)
        activeRecord = updated
        replace(updated)
        selectedRecord = updated
        state = .failed("local_processing_failed")
        recoveryAction = Loc.tr("Local processing failed without uploading meeting data. Check local models and retry.")
    }

    private func recordDirectory(forStem stem: String) -> URL {
        store.rootURL
            .appendingPathComponent("Plaud", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(stem, isDirectory: true)
    }

    private func recordDirectory(for record: MeetingRecord) -> URL {
        store.rootURL
            .appendingPathComponent("Plaud", isDirectory: true)
            .appendingPathComponent("recordings", isDirectory: true)
            .appendingPathComponent(record.stem, isDirectory: true)
    }

    private func select(_ record: MeetingRecord) {
        if selectedRecord?.stem != record.stem {
            // Show any hints already computed for this meeting immediately, so
            // opening it never starts behind an empty "AI is reading..." wait.
            speakerSuggestions = store.cachedSpeakerSuggestions(stem: record.stem)
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
