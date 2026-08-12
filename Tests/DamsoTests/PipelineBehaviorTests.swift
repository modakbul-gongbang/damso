import Foundation
import Testing
@testable import Damso

/// Regression coverage for the synchronous processing/people RPC operations
/// still exposed through `LocalProcessingBackend` (D-13 moved phase-one and
/// summary off this protocol entirely - they are queue-based now, triggered
/// and polled through `RemoteMeetingStore` directly, which needs a real or
/// fake HTTP server rather than this in-memory fake; that coverage now lives
/// in the Python-side loopback integration suite, `test_server_http.py`,
/// plus `test_audio_regression.py` for the real pipeline).
private final class FakeBackend: LocalProcessingBackend, @unchecked Sendable {
    private let lock = NSLock()
    var noteRequests: [LocalPersonNoteRequest] = []
    var rebuildCount = 0
    var noteShouldFail = false

    var applyResolutionsRequests: [LocalResolutionProcessingRequest] = []

    func applyResolutions(_ request: LocalResolutionProcessingRequest) throws -> LocalProcessingResult {
        lock.lock()
        defer { lock.unlock() }
        applyResolutionsRequests.append(request)
        return LocalProcessingResult(ok: true, stage: "ready_for_summary", speakerCount: request.resolutions.count)
    }

    var reclusterRequests: [LocalReclusterRequest] = []

    func recluster(_ request: LocalReclusterRequest) throws -> LocalProcessingResult {
        lock.lock()
        defer { lock.unlock() }
        reclusterRequests.append(request)
        return LocalProcessingResult(ok: true, stage: "speaker_review", speakerCount: request.numSpeakers)
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
        // Write the overlay *before* recording the request. Tests poll
        // `cleanupRequests.count` to learn that a cleanup pass finished and
        // then assert the overlay file exists; appending first makes the
        // counter observable while the file is still unwritten, which failed
        // roughly one run in three.
        try Data("""
        {"version":1,"agent":"claude","corrections":[{"index":0,"text":"인스타 스토리"}]}
        """.utf8).write(to: URL(fileURLWithPath: request.recordingDirectory).appendingPathComponent("transcript.cleaned.json"))
        cleanupRequests.append(request)
        return LocalTranscriptCleanupResult(ok: true, status: "complete", errorCode: nil, correctionCount: 1)
    }

    func rebuildIndex(storeRoot: String) throws -> LocalIndexResult {
        lock.lock()
        defer { lock.unlock() }
        rebuildCount += 1
        return LocalIndexResult(ok: true, meetings: 1)
    }
}

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
func personNoteProposalsOnlyTouchProfilesAfterAcceptance() async throws {
    let (controller, backend, store, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    await controller.applyResolution(speaker: "SPEAKER_00", action: .match, personName: "김구름")
    await controller.applyResolution(speaker: "SPEAKER_01", action: .skip)
    // Summary generation itself is D-13's server-owned queue now (covered by
    // the Python-side loopback suite); this test seeds the proposed note
    // directly to cover only the note propose/reject/accept lifecycle.
    var summarized = try store.load(stem: "pipeline-fixture")
    summarized.personNotes = [PersonNoteProposal(name: "김구름", note: "커리큘럼 초안을 담당한다.", status: .proposed)]
    try store.update(summarized)
    controller.refreshLibrary()
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

/// A regenerated summary replaces the proposals the user has not decided on
/// and keeps the decided ones. Two LLM runs never phrase a note identically,
/// so accumulating by exact `(name, note)` match stacked a near-duplicate
/// proposal per person on every "Generate summary" press (confirmed via a
/// real two-machine run: each participant's proposal showed twice after one
/// re-summary).
@Test @MainActor
func regeneratedSummaryReplacesUndecidedProposalsAndKeepsDecidedOnes() throws {
    let (controller, _, _, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    let existing = [
        PersonNoteProposal(name: "정현준", note: "첫 실행의 문구.", status: .proposed),
        PersonNoteProposal(name: "이호연", note: "첫 실행의 다른 문구.", status: .proposed),
        PersonNoteProposal(name: "김구름", note: "이미 수락한 메모.", status: .accepted),
        PersonNoteProposal(name: "박하늘", note: "이미 거절한 메모.", status: .rejected),
    ]
    let regenerated = [
        PersonNoteProposal(name: "정현준", note: "두 번째 실행의 조금 다른 문구.", status: .proposed),
        PersonNoteProposal(name: "이호연", note: "두 번째 실행의 또 다른 문구.", status: .proposed),
        // An exact match of an already-decided note must not be re-proposed.
        PersonNoteProposal(name: "김구름", note: "이미 수락한 메모.", status: .proposed),
    ]

    let merged = controller.mergedPersonNotes(existing: existing, proposed: regenerated)

    #expect(merged.filter { $0.status == .proposed }.map(\.name).sorted() == ["이호연", "정현준"])
    #expect(merged.filter { $0.status == .proposed }.allSatisfy { $0.note.contains("두 번째") })
    #expect(merged.contains(PersonNoteProposal(name: "김구름", note: "이미 수락한 메모.", status: .accepted)))
    #expect(merged.contains(PersonNoteProposal(name: "박하늘", note: "이미 거절한 메모.", status: .rejected)))
    #expect(merged.count == 4)
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
    let scratch = ScratchDefaults(prefix: "damso-tests-language")
    let isolated = scratch.defaults
    #expect(AgentPreferences.language(isolated) == .korean)
    isolated.set(SummaryLanguage.english.rawValue, forKey: AgentPreferences.languageKey)
    #expect(AgentPreferences.language(isolated) == .english)

    // Catalog lookups per explicit language.
    #expect(Loc.tr("Record now", language: .korean) == "지금 녹음")
    #expect(Loc.tr("Record now", language: .english) == "Record now")
    #expect(Loc.tr("Speakers", language: .korean) == "화자")
}

@Test
func speakerCountPrefillsFromParticipantNamesUntilHandAdjusted() {
    // Adding names while the stepper reads Auto derives names + the user.
    #expect(SpeakerPlan.prefilledCount(current: 0, oldParticipants: [], newParticipants: ["다예"]) == 2)
    #expect(SpeakerPlan.prefilledCount(current: 2, oldParticipants: ["다예"], newParticipants: ["다예", "주은"]) == 3)
    // Removing every name returns the stepper to Auto.
    #expect(SpeakerPlan.prefilledCount(current: 2, oldParticipants: ["다예"], newParticipants: []) == 0)
    // A hand-adjusted count is never overwritten by later name edits.
    #expect(SpeakerPlan.prefilledCount(current: 5, oldParticipants: ["다예"], newParticipants: ["다예", "주은"]) == 5)
    // A fresh session starts at the default (2), which still counts as
    // untouched: adding names past that still derives, it does not stick.
    #expect(SpeakerPlan.prefilledCount(current: SpeakerPlan.defaultCount, oldParticipants: [], newParticipants: ["다예", "주은"]) == 3)
}

@Test @MainActor
func plannedParticipantEditsPrefillThePlannedSpeakerCount() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("damso-prefill-\(UUID().uuidString)")
    let controller = MeetingWorkspaceController(
        store: MeetingStore(root: root, minimumFreeBytes: 0),
        capture: NoopCapture(),
        backend: FakeBackend()
    )
    controller.plannedParticipants = ["다예"]
    #expect(controller.plannedSpeakerCount == 2)
    controller.plannedParticipants = ["다예", "주은"]
    #expect(controller.plannedSpeakerCount == 3)
    controller.plannedSpeakerCount = 5
    controller.plannedParticipants = ["다예"]
    #expect(controller.plannedSpeakerCount == 5)
}

@Test @MainActor
func reclusterReplaysTheProcessingAudioAndRefusesOnceConfirmationStarted() async throws {
    let (controller, backend, store, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    var record = try store.load(stem: "pipeline-fixture")
    record.originalAudioFile = "microphone.caf"
    try store.update(record)
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try Data("synthetic".utf8).write(to: directory.appendingPathComponent("microphone.caf"))
    controller.refreshLibrary()
    controller.select(stem: record.stem)

    await controller.reclusterSpeakers(count: 2)

    #expect(backend.reclusterRequests.count == 1)
    #expect(backend.reclusterRequests.first?.numSpeakers == 2)
    #expect(URL(fileURLWithPath: backend.reclusterRequests.first?.audioPath ?? "").lastPathComponent == "microphone.caf")
    let updated = try store.load(stem: record.stem)
    #expect(updated.hints.numSpeakers == 2)

    // Once any speaker is confirmed, re-splitting would orphan that
    // confirmation, so the action becomes a no-op.
    var confirmed = try store.load(stem: record.stem)
    confirmed.resolutions = [SpeakerResolution(speaker: "SPEAKER_00", action: .skip, personName: nil, alias: nil)]
    try store.update(confirmed)
    controller.refreshLibrary()
    controller.select(stem: record.stem)
    await controller.reclusterSpeakers(count: 3)
    #expect(backend.reclusterRequests.count == 1)
}

/// A retry after an earlier, unrelated failure used to carry that failure's
/// `.failed` state forward even once the retry itself succeeded - `select`
/// only clears `state` on a stem switch, never on repeating the same
/// action against the still-selected meeting (confirmed: a user pressing
/// "Re-split speakers" a second time on the same meeting kept seeing the
/// "Recording needs attention" banner from the first, unrelated failure
/// even after the second attempt actually worked). `reclusterSpeakers` now
/// clears a stale `.failed` state itself at the start of every attempt.
@Test @MainActor
func reclusterClearsAStaleFailedStateBeforeARetryEvenWhenTheRetrySucceeds() async throws {
    let (controller, backend, store, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    // No audio file at all yet - this attempt fails and leaves `state`
    // stuck at `.failed`.
    await controller.reclusterSpeakers(count: 2)
    #expect(controller.state == .failed("recluster_audio_unavailable"))
    #expect(backend.reclusterRequests.isEmpty)

    // Provide the audio and retry on the very same, still-selected meeting.
    var record = try store.load(stem: "pipeline-fixture")
    record.originalAudioFile = "microphone.caf"
    try store.update(record)
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try Data("synthetic".utf8).write(to: directory.appendingPathComponent("microphone.caf"))
    controller.refreshLibrary()
    controller.select(stem: record.stem)

    await controller.reclusterSpeakers(count: 2)

    #expect(backend.reclusterRequests.count == 1)
    #expect(controller.state != .failed("recluster_audio_unavailable"))
}

/// `guardRemoteWrite` itself now sets a `.failed` state consistent with the
/// message it leaves in `recoveryAction`, instead of leaving `state`
/// untouched - the fix landed once in the shared guard rather than at each
/// call site individually, after a per-call-site fix on `reclusterSpeakers`
/// alone left the identical bug reachable through `applyResolution` (a
/// speaker-confirmation click while disconnected looked like it silently
/// did nothing, same shape as the recluster button before its own fix).
/// `.failed` is the only state whose detail text actually reads
/// `recoveryAction` (see `statusDetail`), so any other state left in place
/// on a block renders no visible feedback at all.
@Test @MainActor
func reclusterBlockedByTheRemoteWriteGuardSetsAConsistentFailedState() async throws {
    let backend = FakeBackend()
    let (controller, root) = makeClientWorkspace(status: .disconnected, backend: backend)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MeetingStore(root: root.appendingPathComponent("cache", isDirectory: true), minimumFreeBytes: 0)
    var record = try cache.createRecord(MeetingDraft(stem: "meeting-a", source: .local, title: "meeting-a"))
    record.stage = .speakerReview
    record.originalAudioFile = "microphone.caf"
    try cache.commit(record)
    try cache.update(record)
    controller.refreshLibrary()
    controller.select(stem: "meeting-a")

    await controller.reclusterSpeakers(count: 2)

    #expect(controller.state == .failed("blocked_remote"))
    #expect(controller.recoveryAction == Loc.tr("Available once connected to the Mac mini."))
    #expect(backend.reclusterRequests.isEmpty)
}

/// Same guard, different call site: a speaker-confirmation click while
/// disconnected must be just as visible as a blocked recluster - this is
/// the exact scenario reported live (clicking a person candidate while the
/// Mac mini connection was stale produced no visible reaction).
@Test @MainActor
func applyResolutionBlockedByTheRemoteWriteGuardSetsAConsistentFailedState() async throws {
    let backend = FakeBackend()
    let (controller, root) = makeClientWorkspace(status: .disconnected, backend: backend)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MeetingStore(root: root.appendingPathComponent("cache", isDirectory: true), minimumFreeBytes: 0)
    var record = try cache.createRecord(MeetingDraft(stem: "meeting-a", source: .local, title: "meeting-a"))
    record.stage = .speakerReview
    try cache.commit(record)
    try cache.update(record)
    controller.refreshLibrary()
    controller.select(stem: "meeting-a")

    await controller.applyResolution(speaker: "SPEAKER_00", action: .match, personName: "이호연")

    #expect(controller.state == .failed("blocked_remote"))
    #expect(controller.recoveryAction == Loc.tr("Available once connected to the Mac mini."))
    #expect(backend.applyResolutionsRequests.isEmpty)
}

/// A retry that reaches `applyResolution` again on the same meeting after
/// an earlier, unrelated failure must not carry that failure's `.failed`
/// state forward once the retry succeeds - mirrors the identical recluster
/// regression above, for the other call site the live incident actually hit.
@Test @MainActor
func applyResolutionClearsAStaleFailedStateBeforeARetryEvenWhenTheRetrySucceeds() async throws {
    let (controller, backend, store, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }

    // No audio file at all yet - fails and leaves `state` stuck at `.failed`.
    await controller.reclusterSpeakers(count: 2)
    #expect(controller.state == .failed("recluster_audio_unavailable"))

    await controller.applyResolution(speaker: "SPEAKER_00", action: .match, personName: "이호연")

    #expect(backend.applyResolutionsRequests.count == 1)
    #expect(controller.state != .failed("recluster_audio_unavailable"))
    let updated = try store.load(stem: "pipeline-fixture")
    #expect(updated.resolutions.contains { $0.speaker == "SPEAKER_00" && $0.personName == "이호연" })
}

@Test @MainActor
func cleanupOverlayIsIgnoredWhenItsGenerationDoesNotMatchTheTranscript() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    var record = try store.createRecord(MeetingDraft(stem: "overlay-fixture", source: .local, title: "x"))
    record.stage = .speakerReview
    try store.commit(record)
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try Data(#"{"generation_id":"gen-A","segments":[{"start":0.0,"end":2.0,"speaker":"SPEAKER_00","text":"원문 하나"},{"start":2.0,"end":4.0,"speaker":"SPEAKER_01","text":"원문 둘"}]}"#.utf8)
        .write(to: directory.appendingPathComponent("transcript.raw.json"))
    let overlayURL = directory.appendingPathComponent("transcript.cleaned.json")

    // Matching generation: the correction is applied by index.
    try Data(#"{"generation_id":"gen-A","corrections":[{"index":0,"text":"정리된 하나"}]}"#.utf8).write(to: overlayURL)
    #expect(try store.processingArtifacts(stem: record.stem).cleanedTexts[0] == "정리된 하나")

    // Stale generation (a recluster rewrote the transcript under a new
    // generation_id): the overlay would paint corrections onto the wrong
    // segments, so it is ignored entirely and the raw text stands.
    try Data(#"{"generation_id":"gen-OLD","corrections":[{"index":0,"text":"정리된 하나"}]}"#.utf8).write(to: overlayURL)
    #expect(try store.processingArtifacts(stem: record.stem).cleanedTexts.isEmpty)
}

@Test @MainActor
func reclusterInvalidatesStaleCleanupOverlayAndReRunsCleanup() async throws {
    let (controller, backend, store, root) = try makeWorkspace()
    defer { try? FileManager.default.removeItem(at: root) }
    var record = try store.load(stem: "pipeline-fixture")
    record.originalAudioFile = "microphone.caf"
    try store.update(record)
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try Data("synthetic".utf8).write(to: directory.appendingPathComponent("microphone.caf"))
    controller.refreshLibrary()
    controller.select(stem: record.stem)

    // The first open runs cleanup once and writes the overlay.
    let overlayURL = directory.appendingPathComponent("transcript.cleaned.json")
    for _ in 0..<100 {
        if backend.cleanupRequests.count == 1 { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(backend.cleanupRequests.count == 1)
    #expect(FileManager.default.fileExists(atPath: overlayURL.path))

    await controller.reclusterSpeakers(count: 2)

    // recluster must drop the stale overlay and clear the run-once guard so a
    // fresh cleanup pass runs against the re-clustered transcript, rather than
    // leaving the old overlay to be re-applied by index.
    for _ in 0..<100 {
        if backend.cleanupRequests.count == 2 { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    #expect(backend.reclusterRequests.count == 1)
    #expect(backend.cleanupRequests.count == 2)
    #expect(FileManager.default.fileExists(atPath: overlayURL.path))
}

/// A remote-mode workspace whose connectivity status is pinned for the
/// guard tests below - `RemoteMeetingStore` over the new HTTP client
/// (D-06), never actually dialing out since these tests only exercise
/// `guardRemoteWrite()` firing before any request would be sent.
@MainActor
private func makeClientWorkspace(status: RemoteConnectivityTracker.Status, backend: FakeBackend = FakeBackend()) -> (MeetingWorkspaceController, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
    let outboxRoot = root.appendingPathComponent("outbox", isDirectory: true)
    let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
    try? configuration.configureRemote(host: "mini", port: 8787, token: "token", storeRootPath: "/Volumes/DamsoMini/Application Support/Damso")
    let remoteStore = RemoteMeetingStore(client: DamsoHTTPClient(configuration: configuration), connectionConfiguration: configuration, cacheRoot: cacheRoot, outboxRoot: outboxRoot, needsCacheSync: true)
    let tracker = RemoteConnectivityTracker()
    switch status {
    case .connected: tracker.noteSuccess()
    case .disconnected: tracker.noteFailure(.transportFailed)
    case .versionMismatch: tracker.noteFailure(.remoteUpdateRequired)
    }
    let controller = MeetingWorkspaceController(store: remoteStore, capture: NoopCapture(), backend: backend, connectivityTracker: tracker)
    return (controller, root)
}

@Test @MainActor
func aDisconnectedClientBlocksARemoteWriteAttemptAtCallTimeWithoutRunningIt() async throws {
    let backend = FakeBackend()
    let (controller, root) = makeClientWorkspace(status: .disconnected, backend: backend)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(controller.connectionStatus == .disconnected)

    // No record is even selected (the store is empty) - guardRemoteWrite must
    // fire before any of runSummary's own preconditions get a chance to.
    await controller.runSummary()

    #expect(controller.recoveryAction == Loc.tr("Available once connected to the Mac mini."))
}

@Test @MainActor
func aVersionMismatchBlocksARemoteWriteAttemptWithADistinctMessage() async throws {
    let backend = FakeBackend()
    let (controller, root) = makeClientWorkspace(status: .versionMismatch, backend: backend)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(controller.connectionStatus == .versionMismatch)

    await controller.runSummary()

    #expect(controller.recoveryAction == Loc.tr("The Mac mini needs a Damso update before this can run."))
    #expect(controller.recoveryAction != Loc.tr("Available once connected to the Mac mini."))
}

/// A stale `recoveryAction` from one meeting's failed action must never
/// leak into an unrelated meeting's view - `select` is the only place a
/// failure like the disconnected-write guard above gets cleared, since
/// `recoveryAction` has no per-stem scoping of its own (found via a real
/// two-machine test: the inline recovery banner and "Recording needs
/// attention" header both kept showing an old failure identically on every
/// meeting the user opened afterward, including already-complete ones with
/// nothing wrong).
@Test @MainActor
func selectingADifferentMeetingClearsAStaleRecoveryActionFromTheLastOne() async throws {
    let backend = FakeBackend()
    let (controller, root) = makeClientWorkspace(status: .disconnected, backend: backend)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = MeetingStore(root: root.appendingPathComponent("cache", isDirectory: true), minimumFreeBytes: 0)
    for stem in ["meeting-a", "meeting-b"] {
        var record = try cache.createRecord(MeetingDraft(stem: stem, source: .local, title: stem))
        record.stage = .speakerReview
        record.originalAudioFile = "microphone.caf"
        try cache.commit(record)
        try cache.update(record)
    }
    controller.refreshLibrary()
    controller.select(stem: "meeting-a")

    await controller.runSummary()
    #expect(controller.recoveryAction == Loc.tr("Available once connected to the Mac mini."))

    controller.select(stem: "meeting-b")
    #expect(controller.recoveryAction == nil)
}

@Test @MainActor
func aConnectedClientNeverTripsTheRemoteWriteGuard() async throws {
    let backend = FakeBackend()
    let (controller, root) = makeClientWorkspace(status: .connected, backend: backend)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(controller.connectionStatus == .connected)

    await controller.runSummary()

    // Falls through to runSummary's own "no selected record" no-op instead
    // of the guard's blocked-write message.
    #expect(controller.recoveryAction == nil)
}

// MARK: Two-machine retry (the "recording is broken" false alarm)

/// A record in the steady state every recording reaches on a client: metadata
/// mirrored into this Mac's cache, audio left on the server. Not an error
/// condition - just what a completed handoff looks like from the laptop.
@MainActor
private func seedHandedOffRecord(_ controller: MeetingWorkspaceController, cacheRoot: URL) throws {
    let cache = MeetingStore(root: cacheRoot, minimumFreeBytes: 0)
    var record = try cache.createRecord(MeetingDraft(stem: "local-handed-off", source: .local, title: "Handed off"))
    record.stage = .transcribing
    record.originalAudioFile = "microphone.caf"
    try cache.commit(record)
    try cache.update(record)
    controller.refreshLibrary()
    controller.select(stem: "local-handed-off")
}

@Test @MainActor
func aClientRetryingAHandedOffRecordNeverClaimsItsAudioWentMissing() async throws {
    let backend = FakeBackend()
    let (controller, root) = makeClientWorkspace(status: .connected, backend: backend)
    defer { try? FileManager.default.removeItem(at: root) }
    try seedHandedOffRecord(controller, cacheRoot: root.appendingPathComponent("cache", isDirectory: true))

    await controller.retrySelectedPhaseOne()

    // The defect: this reported a perfectly intact recording as unreprocessable
    // on every retry, because it looked for server-held audio in this Mac's
    // metadata-only cache. Getting past that gate is the whole fix - the write
    // that follows still needs a reachable server, which a unit test has not.
    #expect(controller.state != .failed("recording_source_missing"))
    #expect(controller.state != .failed("recording_not_transferred"))
    #expect(controller.recoveryAction != Loc.tr("The original local audio is unavailable, so this meeting cannot be reprocessed."))
}

@Test @MainActor
func aRecordingStillWaitingInTheOutboxSaysSoRatherThanFailingOnTheServer() async throws {
    let backend = FakeBackend()
    let (controller, root) = makeClientWorkspace(status: .connected, backend: backend)
    defer { try? FileManager.default.removeItem(at: root) }
    // Outbox-only: captured here, never handed over. Its audio exists, but not
    // where the server would look, so a retry must not be sent there at all.
    let outbox = MeetingStore(root: root.appendingPathComponent("outbox", isDirectory: true), minimumFreeBytes: 0)
    var record = try outbox.createRecord(MeetingDraft(stem: "local-pending", source: .local, title: "Pending"))
    record.stage = .transcribing
    record.originalAudioFile = "microphone.caf"
    try outbox.commit(record)
    try outbox.update(record)
    controller.refreshLibrary()
    controller.select(stem: "local-pending")

    await controller.retrySelectedPhaseOne()

    #expect(controller.state == .failed("recording_not_transferred"))
}
