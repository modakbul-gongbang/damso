import Foundation
import Testing
@testable import Damso

/// Regression coverage for the full profile merge (R7): transfer of meeting
/// history, voice embedding, notes, and aliases; archive-first recovery;
/// invalid-selection blocking; unified appearance in listPeople after the
/// merge; and index-rebuild retry with guidance on repeated failure. All
/// tests run against a temporary store and never touch the real one.

@MainActor
private func makeStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    try store.bootstrap()
    return (store, root)
}

private func writeProfile(
    root: URL,
    name: String,
    aliases: [String] = [],
    stems: [String] = [],
    firstSeen: String = "2026-01-01",
    lastSeen: String = "2026-06-01",
    email: String? = nil,
    voice: Bool = false,
    notes: [String] = []
) throws {
    let directory = root.appendingPathComponent("Plaud/peoples/\(MeetingStore.profileSlug(name))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var lines = [
        "name: \"\(name)\"",
        "aliases: \(String(data: try JSONEncoder().encode(aliases), encoding: .utf8)!)",
        "first_seen: \"\(firstSeen)\"",
        "last_seen: \"\(lastSeen)\"",
        "meeting_stems: \(String(data: try JSONEncoder().encode(stems), encoding: .utf8)!)",
        "meeting_count: \(stems.count)",
        "voice_samples: \(voice ? 1 : 0)",
    ]
    if let email { lines.append("email: \"\(email)\"") }
    if voice {
        lines.append("voice_model: \"sherpa-onnx/test-model\"")
        try Data([0x01, 0x02]).write(to: directory.appendingPathComponent("voice.npy"))
    }
    let noteBlock = notes.map { "- (2026-06-01) \($0)" }.joined(separator: "\n")
    let body = "## Description\n\n## Meetings\n\n## Notes\n" + (noteBlock.isEmpty ? "" : noteBlock + "\n")
    try Data(("---\n" + lines.joined(separator: "\n") + "\n---\n" + body).utf8)
        .write(to: directory.appendingPathComponent("profile.md"))
}

struct ProfileMergeTransferTests {
    @Test @MainActor
    func mergeTransfersHistoryVoiceNotesAndAliasesToThePrimary() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProfile(root: root, name: "김가상", aliases: ["Kasang"], stems: ["m-1", "m-2"], firstSeen: "2026-02-01", lastSeen: "2026-05-01")
        try writeProfile(root: root, name: "김가상님", aliases: ["Kasang Kim", "Kasang"], stems: ["m-2", "m-3"], firstSeen: "2026-01-15", lastSeen: "2026-06-10", email: "kasang@example.com", voice: true, notes: ["커리큘럼 담당"])

        let outcome = try store.mergeProfiles(primaryName: "김가상", absorbedName: "김가상님")
        #expect(outcome.primaryName == "김가상")

        let peoples = root.appendingPathComponent("Plaud/peoples")
        let primaryProfile = try String(contentsOf: peoples.appendingPathComponent("김가상/profile.md"), encoding: .utf8)
        // Absorbed name + its aliases accumulate with exact-match dedup
        // ("Kasang" existed on both sides).
        #expect(primaryProfile.contains(#"aliases: ["Kasang","김가상님","Kasang Kim"]"#))
        // Meeting history unions and the count follows the union.
        #expect(primaryProfile.contains(#"meeting_stems: ["m-1","m-2","m-3"]"#))
        #expect(primaryProfile.contains("meeting_count: 3"))
        // First/last seen widen; the primary's missing email transfers.
        #expect(primaryProfile.contains(#"first_seen: "2026-01-15""#))
        #expect(primaryProfile.contains(#"last_seen: "2026-06-10""#))
        #expect(primaryProfile.contains(#"email: "kasang@example.com""#))
        // The primary had no voice profile, so the absorbed one moved over.
        #expect(FileManager.default.fileExists(atPath: peoples.appendingPathComponent("김가상/voice.npy").path))
        #expect(primaryProfile.contains(#"voice_model: "sherpa-onnx/test-model""#))
        // Notes transferred with provenance.
        #expect(primaryProfile.contains("커리큘럼 담당 [김가상님]"))
        // The absorbed folder is gone from active peoples.
        #expect(!FileManager.default.fileExists(atPath: peoples.appendingPathComponent("김가상님").path))
    }

    @Test @MainActor
    func archiveHoldsTheOriginalBeforeAnyTransferAndSupportsRestore() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProfile(root: root, name: "김가상", stems: ["m-1"])
        try writeProfile(root: root, name: "김중복", stems: ["m-2"], voice: true, notes: ["원본 노트"])

        let outcome = try store.mergeProfiles(primaryName: "김가상", absorbedName: "김중복")

        // The archived copy is the verbatim original.
        let archived = try String(contentsOf: outcome.archiveDirectory.appendingPathComponent("profile.md"), encoding: .utf8)
        #expect(archived.contains(#"name: "김중복""#))
        #expect(archived.contains("원본 노트"))
        #expect(FileManager.default.fileExists(atPath: outcome.archiveDirectory.appendingPathComponent("voice.npy").path))

        // Archived profiles never resurface as active people.
        let people = try store.listPeople(records: [])
        #expect(people.map(\.name) == ["김가상"])

        // Restore = move the folder back; the profile is active again.
        let restored = root.appendingPathComponent("Plaud/peoples/김중복", isDirectory: true)
        try FileManager.default.moveItem(at: outcome.archiveDirectory, to: restored)
        #expect(try store.listPeople(records: []).contains { $0.name == "김중복" })
    }

    @Test @MainActor
    func invalidSelectionsAreBlockedWithoutTouchingFiles() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProfile(root: root, name: "김가상", stems: ["m-1"])

        #expect(throws: ProfileMergeError.invalidSelection) {
            try store.mergeProfiles(primaryName: "김가상", absorbedName: "김가상")
        }
        #expect(throws: ProfileMergeError.invalidSelection) {
            try store.mergeProfiles(primaryName: "김가상", absorbedName: "  ")
        }
        #expect(throws: ProfileMergeError.absorbedProfileMissing) {
            try store.mergeProfiles(primaryName: "김가상", absorbedName: "없는사람")
        }
        // Nothing changed and no archive appeared.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Plaud/peoples/archive").path))
    }

    @Test @MainActor
    func historyRecordedUnderTheAbsorbedNameFollowsThePrimaryAfterMerge() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProfile(root: root, name: "김가상", stems: ["m-1"])
        try writeProfile(root: root, name: "김중복", stems: ["m-2"])
        _ = try store.mergeProfiles(primaryName: "김가상", absorbedName: "김중복")

        // A meeting confirmed under the absorbed name aggregates into the
        // unified profile through the alias, so search/history/candidates
        // show only the merged profile (AC11).
        var record = try store.createRecord(MeetingDraft(stem: "merge-history", source: .local, title: "t"))
        record.resolutions = [SpeakerResolution(speaker: "SPEAKER_00", action: .match, personName: "김중복", alias: nil)]
        try store.commit(record)
        let people = try store.listPeople(records: [record])
        #expect(people.map(\.name) == ["김가상"])
        #expect(people.first?.meetingCount == 1)
    }
}

// MARK: - Workspace merge flow: rebuild retry and guidance

private final class MergeFakeBackend: LocalProcessingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _rebuildCalls = 0
    var rebuildResults: [Bool]

    init(rebuildResults: [Bool]) {
        self.rebuildResults = rebuildResults
    }

    var rebuildCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _rebuildCalls
    }

    func rebuildIndex(storeRoot: String) throws -> LocalIndexResult {
        lock.lock()
        defer { lock.unlock() }
        _rebuildCalls += 1
        let ok = rebuildResults.isEmpty ? true : rebuildResults.removeFirst()
        if !ok { throw LocalProcessingCommandError.failed }
        return LocalIndexResult(ok: true, meetings: 0)
    }

    func runPhaseOne(_ request: LocalProcessingRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func applyResolutions(_ request: LocalResolutionProcessingRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func appendPersonNote(_ request: LocalPersonNoteRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func refreshCandidates(_ request: LocalRefreshCandidatesRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func setPersonEmail(_ request: LocalPersonEmailRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func removePersonAlias(_ request: LocalRemovePersonAliasRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func runSummary(_ request: LocalSummaryRequest) throws -> LocalSummaryResult { fatalError("unused") }
    func suggestSpeakers(_ request: LocalSpeakerHintsRequest) throws -> LocalSpeakerHintsResult { fatalError("unused") }
    func cleanTranscript(_ request: LocalTranscriptCleanupRequest) throws -> LocalTranscriptCleanupResult { fatalError("unused") }
}

@MainActor
private final class MergeNoopCapture: RecordingCapture {
    func permissionState() async -> RecordingPermissionState { .ready }
    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles { fatalError("unused") }
    func stop() async throws -> CapturedAudioFiles { fatalError("unused") }
}

struct ProfileMergeWorkspaceTests {
    @Test @MainActor
    func rebuildFailureRetriesOnceThenPointsAtTheSettingsReindexAction() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProfile(root: root, name: "김가상", stems: ["m-1"])
        try writeProfile(root: root, name: "김중복", stems: ["m-2"])
        let backend = MergeFakeBackend(rebuildResults: [false, false])
        let controller = MeetingWorkspaceController(store: store, capture: MergeNoopCapture(), backend: backend)

        #expect(await controller.mergeProfiles(primaryName: "김가상", absorbedName: "김중복"))
        #expect(backend.rebuildCalls == 2)
        #expect(controller.recoveryAction?.contains("Rebuild index") == true || controller.recoveryAction?.contains("인덱스") == true)
        // The merge itself still happened; files stay authoritative.
        #expect(try store.listPeople(records: []).map(\.name) == ["김가상"])
    }

    @Test @MainActor
    func transientRebuildFailureRecoversOnTheAutomaticRetry() async throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProfile(root: root, name: "김가상", stems: ["m-1"])
        try writeProfile(root: root, name: "김중복", stems: ["m-2"])
        let backend = MergeFakeBackend(rebuildResults: [false, true])
        let controller = MeetingWorkspaceController(store: store, capture: MergeNoopCapture(), backend: backend)

        #expect(await controller.mergeProfiles(primaryName: "김가상", absorbedName: "김중복"))
        #expect(backend.rebuildCalls == 2)
        #expect(controller.recoveryAction == nil)
    }
}
