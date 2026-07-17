import Foundation
import Testing
@testable import Damso

@MainActor
private final class DeniedCapture: RecordingCapture {
    func permissionState() async -> RecordingPermissionState { .microphoneDenied }

    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles {
        fatalError("Capture must not start when permission is denied")
    }

    func stop() async throws -> CapturedAudioFiles {
        fatalError("Capture must not stop when permission is denied")
    }
}

@Test
func localProcessingCommandUsesTheFixedModuleAndStdinOnly() {
    let command = LocalProcessingCommand(pythonExecutable: "python3")
    #expect(command.arguments == ["python3", "-m", "damso.processing", "--request", "-"])
    #expect(!command.arguments.joined(separator: " ").contains("transcript"))
    #expect(!command.arguments.joined(separator: " ").contains("http"))
}

@Test
func localProcessingRequestUsesOnlyCanonicalPathsAndHintFields() throws {
    let request = LocalProcessingRequest(
        recordingDirectory: "/tmp/Plaud/recordings/fixture",
        audioPath: "/tmp/Plaud/recordings/fixture/microphone.caf",
        hints: LocalProcessingHints(.empty)
    )
    let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    #expect(fields?["operation"] as? String == "phase-one")
    #expect(fields?["recording_directory"] as? String != nil)
    #expect(fields?["audio_path"] as? String != nil)
    #expect(fields?["transcript"] == nil)
}

@Test
func speakerResolutionRequestCarriesOnlyCanonicalPathsAndExplicitResolutions() throws {
    let request = LocalResolutionProcessingRequest(
        recordingDirectory: "/tmp/Plaud/recordings/fixture",
        peoplesDirectory: "/tmp/Plaud/peoples",
        meetingDate: "2026-07-15",
        resolutions: ["SPEAKER_00": LocalSpeakerResolution(action: "new", name: "Kim")]
    )
    let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    #expect(fields?["operation"] as? String == "apply-resolutions")
    #expect(fields?["recording_directory"] as? String == "/tmp/Plaud/recordings/fixture")
    #expect(fields?["peoples_directory"] as? String == "/tmp/Plaud/peoples")
    #expect((fields?["resolutions"] as? [String: [String: String]])?["SPEAKER_00"]?["name"] == "Kim")
    #expect(fields?["transcript"] == nil)
}

@Test
func localSummaryCommandUsesTheFixedModuleAndNeverCarriesTranscriptText() throws {
    let command = LocalSummaryCommand(pythonExecutable: "python3")
    #expect(command.arguments == ["python3", "-m", "damso.summary", "--request", "-"])
    let request = LocalSummaryRequest(recordingDirectory: "/tmp/Plaud/recordings/fixture", agent: .codex, language: .korean)
    let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    #expect(fields?["recording_directory"] as? String == "/tmp/Plaud/recordings/fixture")
    #expect(fields?["agent"] as? String == "codex")
    #expect(fields?["language"] as? String == "ko")
    #expect(fields?["sensitive"] == nil)
    #expect(fields?["transcript"] == nil)
    #expect(fields?["summary"] == nil)
}

@Test
func personNoteRequestCarriesOnlyTheAcceptedNoteAndCanonicalPaths() throws {
    let request = LocalPersonNoteRequest(
        recordingDirectory: "/tmp/Plaud/recordings/fixture",
        peoplesDirectory: "/tmp/Plaud/peoples",
        meetingDate: "2026-07-16",
        name: "Kim",
        note: "Owns the launch checklist."
    )
    let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    #expect(fields?["operation"] as? String == "append-person-note")
    #expect(fields?["name"] as? String == "Kim")
    #expect(fields?["note"] as? String == "Owns the launch checklist.")
    #expect(fields?["transcript"] == nil)
}

@Test
func processingArtifactsReadExistingCanonicalFilesWithoutStartingProcessing() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    let record = try store.createRecord(MeetingDraft(stem: "artifact-fixture", source: .local, title: "Synthetic fixture"))
    try store.commit(record)
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try Data("""
    {"segments":[{"start":0.0,"end":2.5,"speaker":"SPEAKER_01","text":"Local fixture"}]}
    """.utf8).write(to: directory.appendingPathComponent("transcript.raw.json"))
    try Data("""
    {"proposals":{"SPEAKER_01":{"total_seconds":2.5,"segment_count":1,"excerpts":[{"start":0.0,"end":2.5,"text":"Local fixture"}],"candidates":[{"name":"Known person","voice_score":0.87}]}}}
    """.utf8).write(to: directory.appendingPathComponent("identification.json"))

    let artifacts = try store.processingArtifacts(stem: record.stem)

    #expect(artifacts.transcript == [TranscriptSegment(speaker: "SPEAKER_01", startSeconds: 0, endSeconds: 2.5, text: "Local fixture")])
    #expect(artifacts.proposals.count == 1)
    #expect(artifacts.proposals[0].speaker == "SPEAKER_01")
    #expect(artifacts.proposals[0].candidates == [SpeakerCandidate(name: "Known person", voiceScore: 0.87)])
}

@Test
func storedSummaryMapsTheBoundedLocalArtifactIntoMeetingMetadata() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    let record = try store.createRecord(MeetingDraft(stem: "summary-fixture", source: .local, title: "Synthetic fixture"))
    try store.commit(record)
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try Data("""
    {"title":"온보딩 워크숍 커리큘럼 논의","role_hint":"Facilitator","topic_summary":"Synthetic topic","one_line_summary":"Synthetic line","key_points":["One point"],"action_items":[{"task":"Follow up","owner":"Kim","due":"Friday"}],"person_notes":[{"name":"Kim","note":"Owns the launch checklist."}]}
    """.utf8).write(to: directory.appendingPathComponent("summary.json"))

    let artifact = try #require(try store.storedSummaryArtifact(stem: record.stem))
    let summary = artifact.summary

    #expect(summary.oneLine == "Synthetic line")
    #expect(summary.keyDiscussion == ["One point"])
    #expect(summary.actionItems == ["Follow up · Owner: Kim · Due: Friday"])
    #expect(summary.roleHints == ["Meeting role": "Facilitator"])
    #expect(artifact.agentTitle == "온보딩 워크숍 커리큘럼 논의")
    #expect(artifact.personNotes == [PersonNoteProposal(name: "Kim", note: "Owns the launch checklist.", status: .proposed)])
}

@Test
func storedSummaryWithoutTitleOrNotesStillMapsForOlderArtifacts() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    let record = try store.createRecord(MeetingDraft(stem: "legacy-summary-fixture", source: .local, title: "Synthetic fixture"))
    try store.commit(record)
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try Data("""
    {"role_hint":"","topic_summary":"Topic","one_line_summary":"Line","key_points":[],"action_items":[]}
    """.utf8).write(to: directory.appendingPathComponent("summary.json"))

    let artifact = try #require(try store.storedSummaryArtifact(stem: record.stem))
    #expect(artifact.agentTitle == nil)
    #expect(artifact.personNotes.isEmpty)
    #expect(artifact.summary.oneLine == "Line")
}

@Test
func meetingTitleComposerUsesLocalRecordingStartHour() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
    var components = DateComponents()
    components.year = 2026
    components.month = 7
    components.day = 13
    components.hour = 19
    components.minute = 9
    let createdAt = calendar.date(from: components)!

    let composed = MeetingTitleComposer.compose(agentTitle: "온보딩 워크숍 커리큘럼 논의", createdAt: createdAt, calendar: calendar)

    #expect(composed == "2026071319-온보딩 워크숍 커리큘럼 논의")
    #expect(MeetingTitleComposer.hasComposedPrefix(composed))
    #expect(!MeetingTitleComposer.hasComposedPrefix("Untitled local meeting"))
    #expect(MeetingTitleComposer.compose(agentTitle: "  \n ", createdAt: createdAt, calendar: calendar) == "2026071319")
}

@Test @MainActor
func recordActionFailsBeforeCreatingARecordWhenPermissionIsDenied() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = MeetingWorkspaceController(store: MeetingStore(root: root), capture: DeniedCapture())
    await controller.performPrimaryAction()
    #expect(controller.state == .failed("recording_permission_required"))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Plaud/recordings").path))
}

@Test
func staleIdentificationCandidatesAreFilteredAndSortedForDisplay() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    let record = try store.createRecord(MeetingDraft(stem: "candidate-fixture", source: .local, title: "Fixture"))
    try store.commit(record)
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try Data("""
    {"segments":[{"start":0.0,"end":1.0,"speaker":"SPEAKER_00","text":"fixture"}]}
    """.utf8).write(to: directory.appendingPathComponent("transcript.raw.json"))
    try Data("""
    {"proposals":{"SPEAKER_00":{"total_seconds":1.0,"segment_count":1,"excerpts":[],"candidates":[
      {"name":"노이즈","voice_score":-0.14},
      {"name":"중간","voice_score":0.36},
      {"name":"강함","voice_score":0.88}
    ]}}}
    """.utf8).write(to: directory.appendingPathComponent("identification.json"))

    let artifacts = try store.processingArtifacts(stem: record.stem)

    #expect(artifacts.proposals[0].candidates.map(\.name) == ["강함", "중간"])
}

@Test
func processRuntimePathPrefersUserToolDirectoriesAndKeepsSystemFallback() {
    let environment = ProcessRuntime.environment()
    let path = environment["PATH"] ?? ""
    let entries = path.split(separator: ":").map(String.init)
    #expect(entries.contains("/usr/bin"))
    #expect(environment["HOME"]?.isEmpty == false)
    // Any well-known directory that exists on this machine must come before
    // the system /usr/bin so a user Python wins over the system one.
    let home = environment["HOME"]!
    for known in ["\(home)/.pyenv/shims", "/opt/homebrew/bin", "\(home)/.local/bin"] where FileManager.default.fileExists(atPath: known) {
        let knownIndex = entries.firstIndex(of: known)
        let systemIndex = entries.firstIndex(of: "/usr/bin")
        #expect(knownIndex != nil && systemIndex != nil && knownIndex! < systemIndex!)
    }
}
