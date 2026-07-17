import Foundation
import Testing
@testable import Damso

/// Regression coverage for the automatic pipeline: the speaker gate is the
/// only manual step, closing it runs the summary/title automatically, crash
/// interruptions resume, failures stay retryable, and person-note proposals
/// only touch profiles after acceptance.
private final class FakeBackend: LocalProcessingBackend, @unchecked Sendable {
    private let lock = NSLock()
    var summaryRequests: [LocalSummaryRequest] = []
    var noteRequests: [LocalPersonNoteRequest] = []
    var rebuildCount = 0
    var summaryArtifact: String?
    var summaryResult = LocalSummaryResult(ok: true, status: "complete", errorCode: nil)
    var noteShouldFail = false

    func runPhaseOne(_ request: LocalProcessingRequest) throws -> LocalProcessingResult {
        LocalProcessingResult(ok: true, stage: "speaker_review", speakerCount: 0)
    }

    func applyResolutions(_ request: LocalResolutionProcessingRequest) throws -> LocalProcessingResult {
        LocalProcessingResult(ok: true, stage: "ready_for_summary", speakerCount: request.resolutions.count)
    }

    func appendPersonNote(_ request: LocalPersonNoteRequest) throws -> LocalProcessingResult {
        lock.lock()
        defer { lock.unlock() }
        if noteShouldFail { throw LocalProcessingCommandError.failed }
        noteRequests.append(request)
        return LocalProcessingResult(ok: true, stage: "person_note_saved", speakerCount: nil)
    }

    var refreshRequests: [LocalRefreshCandidatesRequest] = []
    var hintsRequests: [LocalSpeakerHintsRequest] = []
    var hintsResult = LocalSpeakerHintsResult(ok: true, status: "complete", errorCode: nil, suggestions: [
        SpeakerSuggestion(speaker: "SPEAKER_01", name: "이노을", confidence: 0.7, reason: "자기소개에서 언급"),
    ])

    func refreshCandidates(_ request: LocalRefreshCandidatesRequest) throws -> LocalProcessingResult {
        lock.lock()
        defer { lock.unlock() }
        refreshRequests.append(request)
        return LocalProcessingResult(ok: true, stage: "candidates_refreshed", speakerCount: 2)
    }

    var emailRequests: [LocalPersonEmailRequest] = []

    func setPersonEmail(_ request: LocalPersonEmailRequest) throws -> LocalProcessingResult {
        lock.lock()
        defer { lock.unlock() }
        emailRequests.append(request)
        return LocalProcessingResult(ok: true, stage: "person_email_saved", speakerCount: nil)
    }

    var aliasRemovals: [LocalRemovePersonAliasRequest] = []

    func removePersonAlias(_ request: LocalRemovePersonAliasRequest) throws -> LocalProcessingResult {
        lock.lock()
        defer { lock.unlock() }
        aliasRemovals.append(request)
        return LocalProcessingResult(ok: true, stage: "person_alias_removed", speakerCount: nil)
    }

    func suggestSpeakers(_ request: LocalSpeakerHintsRequest) throws -> LocalSpeakerHintsResult {
        lock.lock()
        defer { lock.unlock() }
        hintsRequests.append(request)
        return hintsResult
    }

    var cleanupRequests: [LocalTranscriptCleanupRequest] = []

    func cleanTranscript(_ request: LocalTranscriptCleanupRequest) throws -> LocalTranscriptCleanupResult {
        lock.lock()
        defer { lock.unlock() }
        cleanupRequests.append(request)
        try Data("""
        {"version":1,"agent":"claude","corrections":[{"index":0,"text":"인스타 스토리"}]}
        """.utf8).write(to: URL(fileURLWithPath: request.recordingDirectory).appendingPathComponent("transcript.cleaned.json"))
        return LocalTranscriptCleanupResult(ok: true, status: "complete", errorCode: nil, correctionCount: 1)
    }

    func runSummary(_ request: LocalSummaryRequest) throws -> LocalSummaryResult {
        lock.lock()
        defer { lock.unlock() }
        summaryRequests.append(request)
        if let summaryArtifact {
            try Data(summaryArtifact.utf8).write(to: URL(fileURLWithPath: request.recordingDirectory).appendingPathComponent("summary.json"))
        }
        return summaryResult
    }

    func rebuildIndex(storeRoot: String) throws -> LocalIndexResult {
        lock.lock()
        defer { lock.unlock() }
        rebuildCount += 1
        return LocalIndexResult(ok: true, meetings: 1)
    }
}

private let summaryFixture = """
{"title":"온보딩 워크숍 커리큘럼 논의","role_hint":"Facilitator","topic_summary":"Topic","one_line_summary":"Line","key_points":["Point"],"action_items":[],"person_notes":[{"name":"김구름","note":"커리큘럼 초안을 담당한다."}]}
"""

@MainActor
private func makeWorkspace(stage: ProcessingStage = .speakerReview, resolutions: [SpeakerResolution] = []) throws -> (MeetingWorkspaceController, FakeBackend, MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    var record = try store.createRecord(MeetingDraft(stem: "pipeline-fixture", source: .local, title: "Untitled local meeting"))
    record.stage = stage
    record.resolutions = resolutions
    try store.commit(record)
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try Data("""
    {"segments":[{"start":0.0,"end":2.0,"speaker":"SPEAKER_00","text":"인스타 스토리 공유"},{"start":2.0,"end":4.0,"speaker":"SPEAKER_01","text":"커리큘럼 초안"}]}
    """.utf8).write(to: directory.appendingPathComponent("transcript.raw.json"))
    try Data("""
    {"proposals":{"SPEAKER_00":{"total_seconds":2.0,"segment_count":1,"excerpts":[],"candidates":[{"name":"김구름","voice_score":0.88}]},"SPEAKER_01":{"total_seconds":2.0,"segment_count":1,"excerpts":[],"candidates":[]}}}
    """.utf8).write(to: directory.appendingPathComponent("identification.json"))
    let backend = FakeBackend()
    backend.summaryArtifact = summaryFixture
    let controller = MeetingWorkspaceController(store: store, capture: NoopCapture(), backend: backend)
    controller.refreshLibrary()
    controller.select(stem: record.stem)
    return (controller, backend, store, root)
}

@MainActor
private final class NoopCapture: RecordingCapture {
    func permissionState() async -> RecordingPermissionState { .ready }
    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles { fatalError("unused") }
    func stop() async throws -> CapturedAudioFiles { fatalError("unused") }
}

@Test @MainActor
func generatingTheSummaryAfterConfirmingSpeakersComposesTheDisplayTitle() async throws {
    let (controller, backend, store, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    await controller.applyResolution(speaker: "SPEAKER_00", action: .match, personName: "김구름")
    #expect(backend.summaryRequests.isEmpty)
    #expect(controller.selectedRecord?.stage == .speakerReview)

    // Confirming the last speaker no longer auto-summarizes: the transcript
    // is sent to the agent only when the user presses Generate summary.
    await controller.applyResolution(speaker: "SPEAKER_01", action: .new, personName: "이노을")
    #expect(backend.summaryRequests.isEmpty)
    #expect(controller.selectedRecord?.stage == .speakerReview)

    await controller.runSummary()

    #expect(backend.summaryRequests.count == 1)
    #expect(backend.summaryRequests.first?.language == "ko")
    let record = try store.load(stem: "pipeline-fixture")
    #expect(record.stage == .complete)
    #expect(record.title.hasSuffix("-온보딩 워크숍 커리큘럼 논의"))
    #expect(MeetingTitleComposer.hasComposedPrefix(record.title))
    #expect(record.summary?.oneLine == "Line")
    #expect(record.personNotes == [PersonNoteProposal(name: "김구름", note: "커리큘럼 초안을 담당한다.", status: .proposed)])
}

@Test @MainActor
func summaryFailureKeepsSpeakerConfirmationsAndStaysRetryable() async throws {
    let (controller, backend, store, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    backend.summaryArtifact = nil
    backend.summaryResult = LocalSummaryResult(ok: true, status: "failed", errorCode: "agent_cli_missing")

    await controller.applyResolution(speaker: "SPEAKER_00", action: .match, personName: "김구름")
    await controller.applyResolution(speaker: "SPEAKER_01", action: .skip)
    await controller.runSummary()

    let failed = try store.load(stem: "pipeline-fixture")
    #expect(failed.stage == .partial)
    #expect(failed.lastErrorCode == "agent_cli_missing")
    #expect(failed.resolutions.count == 2)
    #expect(controller.recoveryAction != nil)

    backend.summaryArtifact = summaryFixture
    backend.summaryResult = LocalSummaryResult(ok: true, status: "complete", errorCode: nil)
    await controller.runSummary()

    let recovered = try store.load(stem: "pipeline-fixture")
    #expect(recovered.stage == .complete)
    #expect(recovered.summary != nil)
    #expect(recovered.resolutions.count == 2)
}

@Test @MainActor
func summaryInterruptedByACrashResumesOnceOnNextLaunch() async throws {
    let resolutions = [
        SpeakerResolution(speaker: "SPEAKER_00", action: .match, personName: "김구름"),
        SpeakerResolution(speaker: "SPEAKER_01", action: .skip, personName: nil),
    ]
    let (controller, backend, store, root) = try makeWorkspace(stage: .summarizing, resolutions: resolutions)
    defer { try? FileManager.default.removeItem(at: root) }

    await controller.resumeInterruptedSummaries()
    #expect(backend.summaryRequests.count == 1)
    #expect(try store.load(stem: "pipeline-fixture").stage == .complete)

    await controller.resumeInterruptedSummaries()
    #expect(backend.summaryRequests.count == 1)
}

@Test @MainActor
func personNoteProposalsOnlyTouchProfilesAfterAcceptance() async throws {
    let (controller, backend, store, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.applyResolution(speaker: "SPEAKER_00", action: .match, personName: "김구름")
    await controller.applyResolution(speaker: "SPEAKER_01", action: .skip)
    await controller.runSummary()
    let proposal = try #require(controller.selectedRecord?.personNotes?.first)

    controller.rejectPersonNote(proposal)
    #expect(backend.noteRequests.isEmpty)
    #expect(try store.load(stem: "pipeline-fixture").personNotes?.first?.status == .rejected)

    var record = try store.load(stem: "pipeline-fixture")
    record.personNotes = [PersonNoteProposal(name: "김구름", note: "커리큘럼 초안을 담당한다.", status: .proposed)]
    try store.update(record)
    controller.refreshLibrary()
    let restored = try #require(controller.selectedRecord?.personNotes?.first)

    await controller.acceptPersonNote(restored, editedNote: "커리큘럼 전체를 리드한다.")
    #expect(backend.noteRequests.count == 1)
    #expect(backend.noteRequests.first?.note == "커리큘럼 전체를 리드한다.")
    #expect(try store.load(stem: "pipeline-fixture").personNotes?.first?.status == .accepted)
}

@Test @MainActor
func skippedSpeakersNeverJoinTheMeetingHistory() async throws {
    let (controller, _, store, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.applyResolution(speaker: "SPEAKER_00", action: .match, personName: "김구름")
    await controller.applyResolution(speaker: "SPEAKER_01", action: .skip)

    let people = try store.listPeople(records: [store.load(stem: "pipeline-fixture")])
    #expect(people.map(\.name) == ["김구름"])
}

@Test @MainActor
func openingAnUnresolvedMeetingFetchesSuggestionsAutomaticallyWithoutMutatingTheRecord() async throws {
    let (controller, backend, store, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = try store.load(stem: "pipeline-fixture")

    // Suggestions start from select() inside makeWorkspace; selecting again
    // must not re-request within the same session.
    controller.select(stem: "pipeline-fixture")
    for _ in 0..<50 where controller.speakerSuggestions.isEmpty {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    #expect(backend.hintsRequests.count == 1)
    #expect(backend.hintsRequests.first?.language == "ko")
    #expect(controller.speakerSuggestions["SPEAKER_01"]?.first?.name == "이노을")
    #expect(try store.load(stem: "pipeline-fixture") == before)
}

@Test @MainActor
func openingAnUnresolvedMeetingRefreshesVoiceCandidatesOncePerSession() async throws {
    let (controller, backend, _, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    controller.select(stem: "pipeline-fixture")
    controller.select(stem: "pipeline-fixture")
    try await Task.sleep(nanoseconds: 200_000_000)

    #expect(backend.refreshRequests.count == 1)
}

@Test @MainActor
func openingATranscribedMeetingRunsTheCleanupOverlayOncePerMeeting() async throws {
    let (controller, backend, _, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    // Cleanup starts from select() inside makeWorkspace; re-selecting must
    // not re-request once the overlay file exists.
    controller.select(stem: "pipeline-fixture")
    for _ in 0..<50 where controller.processingArtifacts.cleanedTexts.isEmpty {
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    controller.select(stem: "pipeline-fixture")
    try await Task.sleep(nanoseconds: 100_000_000)

    #expect(backend.cleanupRequests.count == 1)
    #expect(controller.processingArtifacts.cleanedTexts == [0: "인스타 스토리"])
    // The original transcript file is untouched by cleanup.
    let raw = CanonicalStoreLayout(root: root).recordDirectory(stem: "pipeline-fixture").appendingPathComponent("transcript.raw.json")
    let contents = try String(contentsOf: raw, encoding: .utf8)
    #expect(contents.contains("인스타 스토리 공유"))
}

@Test
func overlappingLocalAndPlaudRecordingsAreFlaggedAsDuplicateSuspects() {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let local = MeetingRecord(stem: "local-a", source: .local, title: "A", createdAt: base, durationSeconds: 1_800)
    let plaud = MeetingRecord(stem: "plaud-b", source: .plaud, title: "B", createdAt: base.addingTimeInterval(30), durationSeconds: 1_790)
    let unrelated = MeetingRecord(stem: "local-c", source: .local, title: "C", createdAt: base.addingTimeInterval(90_000), durationSeconds: 600)
    let sameSource = MeetingRecord(stem: "local-d", source: .local, title: "D", createdAt: base.addingTimeInterval(20), durationSeconds: 1_800)

    let suspects = DuplicateSuspects.stems(in: [local, plaud, unrelated, sameSource])

    #expect(suspects.contains("local-a"))
    #expect(suspects.contains("plaud-b"))
    #expect(!suspects.contains("local-c"))
}

@Test
func localizationCatalogServesKoreanByDefaultAndEnglishWhenSelected() {
    // Language resolution defaults to Korean; checked against an isolated
    // defaults suite so no global state is mutated (tests run in parallel
    // and every Loc.tr call in other suites reads the global preference).
    let isolated = UserDefaults(suiteName: "damso-tests-language-\(UUID().uuidString)")!
    #expect(AgentPreferences.language(isolated) == .korean)
    isolated.set(SummaryLanguage.english.rawValue, forKey: AgentPreferences.languageKey)
    #expect(AgentPreferences.language(isolated) == .english)

    // Catalog lookups per explicit language.
    #expect(Loc.tr("Record now", language: .korean) == "지금 녹음")
    #expect(Loc.tr("Record now", language: .english) == "Record now")
    #expect(Loc.tr("Speakers", language: .korean) == "화자")
}
