import Foundation
import Testing
@testable import Damso

/// Regression coverage for speaker-confirmation integration (R6, R9):
/// active-speaker time-axis majority vote, participant candidate merge into
/// speaker proposals, alias reading/search/candidate matching, and the alias
/// payload sent on confirmation. All fixtures use synthetic names.

private func segment(_ speaker: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: speaker, startSeconds: start, endSeconds: end, text: "말")
}

private func participant(_ name: String, samples: [Double]?) -> MeetingParticipantRecord {
    MeetingParticipantRecord(
        name: name,
        firstSeenAt: Date(timeIntervalSince1970: 0),
        lastSeenAt: Date(timeIntervalSince1970: 60),
        source: "chrome-meet",
        speakingSamples: samples
    )
}

struct SpeakerMatchingMajorityVoteTests {
    @Test
    func majorityVotePicksTheDominantSpeakerPerDiarizationTrack() {
        let segments = [segment("SPEAKER_00", 0, 10), segment("SPEAKER_01", 10, 20)]
        let participants = [
            participant("김가상", samples: [1, 2, 3, 11]),
            participant("박테스트", samples: [12, 13]),
        ]
        let suggestions = ActiveSpeakerMajorityVote.suggestions(segments: segments, participants: participants)
        #expect(suggestions["SPEAKER_00"] == "김가상")
        #expect(suggestions["SPEAKER_01"] == "박테스트")
    }

    @Test
    func tieBreaksDeterministicallyAndBoundariesAreHalfOpen() {
        let segments = [segment("SPEAKER_00", 0, 10)]
        let participants = [
            participant("나중이름", samples: [1, 2]),
            participant("가나다", samples: [3, 4]),
        ]
        // Two votes each: the alphabetically first name wins every reload.
        let tied = ActiveSpeakerMajorityVote.suggestions(segments: segments, participants: participants)
        #expect(tied["SPEAKER_00"] == "가나다")

        // A sample exactly at a segment end belongs to the next segment.
        let two = [segment("SPEAKER_00", 0, 10), segment("SPEAKER_01", 10, 20)]
        let edge = ActiveSpeakerMajorityVote.suggestions(segments: two, participants: [participant("경계", samples: [10])])
        #expect(edge["SPEAKER_00"] == nil)
        #expect(edge["SPEAKER_01"] == "경계")
    }

    @Test
    func noSamplesOrNoSegmentsProduceNoSuggestions() {
        #expect(ActiveSpeakerMajorityVote.suggestions(segments: [], participants: [participant("김가상", samples: [1])]).isEmpty)
        #expect(ActiveSpeakerMajorityVote.suggestions(
            segments: [segment("SPEAKER_00", 0, 10)],
            participants: [participant("김가상", samples: nil)]
        ).isEmpty)
    }
}

// MARK: - Artifacts integration

private let transcriptFixture = """
{"segments":[{"start":0.0,"end":10.0,"speaker":"SPEAKER_00","text":"안건 공유"},{"start":10.0,"end":20.0,"speaker":"SPEAKER_01","text":"진행 상황"}]}
"""

private let identificationFixture = """
{"proposals":{"SPEAKER_00":{"total_seconds":10.0,"segment_count":1,"excerpts":[],"candidates":[{"name":"김가상","voice_score":0.9}]},"SPEAKER_01":{"total_seconds":10.0,"segment_count":1,"excerpts":[],"candidates":[]}}}
"""

private let participantsFixture = """
{"version":1,"participants":[
  {"name":"김가상","firstSeenAt":"2026-07-16T10:00:00.000Z","lastSeenAt":"2026-07-16T10:30:00.000Z","source":"chrome-meet","speakingSamples":[1.0,2.0]},
  {"name":"박테스트","firstSeenAt":"2026-07-16T10:00:00.000Z","lastSeenAt":"2026-07-16T10:30:00.000Z","source":"chrome-meet","speakingSamples":[11.0,12.0,13.0]},
  {"name":"이늦참","firstSeenAt":"2026-07-16T10:15:00.000Z","lastSeenAt":"2026-07-16T10:30:00.000Z","source":"chrome-meet"}
]}
"""

private func makeStore(withParticipants: Bool) throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    let record = try store.createRecord(MeetingDraft(stem: "matching-fixture", source: .local, title: "Untitled"))
    try store.commit(record)
    let directory = CanonicalStoreLayout(root: root).recordDirectory(stem: record.stem)
    try Data(transcriptFixture.utf8).write(to: directory.appendingPathComponent("transcript.raw.json"))
    try Data(identificationFixture.utf8).write(to: directory.appendingPathComponent("identification.json"))
    if withParticipants {
        try Data(participantsFixture.utf8).write(to: directory.appendingPathComponent("participants.json"))
    }
    return (store, root)
}

struct SpeakerMatchingArtifactsTests {
    @Test
    func participantsAppearAsCandidatesWithTheMajorityWinnerFirst() throws {
        let (store, root) = try makeStore(withParticipants: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = try store.processingArtifacts(stem: "matching-fixture")
        let bySpeaker = Dictionary(uniqueKeysWithValues: artifacts.proposals.map { ($0.speaker, $0) })

        let first = try #require(bySpeaker["SPEAKER_00"])
        // 김가상 is already a voice candidate, so only the other captured
        // names join as participant candidates.
        #expect(first.candidates.map(\.name) == ["김가상"])
        #expect(first.participantCandidates == ["박테스트", "이늦참"])
        #expect(first.suggestedParticipant == "김가상")

        let second = try #require(bySpeaker["SPEAKER_01"])
        #expect(second.suggestedParticipant == "박테스트")
        // The majority winner leads the participant candidate list.
        #expect(second.participantCandidates.first == "박테스트")
        #expect(Set(second.participantCandidates) == Set(["김가상", "박테스트", "이늦참"]))
    }

    @Test
    func meetingsWithoutParticipantsFileKeepTheExistingFlow() throws {
        let (store, root) = try makeStore(withParticipants: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = try store.processingArtifacts(stem: "matching-fixture")
        for proposal in artifacts.proposals {
            #expect(proposal.participantCandidates.isEmpty)
            #expect(proposal.suggestedParticipant == nil)
        }
    }
}

// MARK: - Alias model (R9, AC14)

struct SpeakerMatchingAliasTests {
    @Test
    func aliasesAreReadFromProfilesAndUsedForSearchAndMatching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(root: root, minimumFreeBytes: 0)
        try store.bootstrap()
        let directory = root.appendingPathComponent("Plaud/peoples/김가상", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("""
        ---
        name: "김가상"
        aliases: ["김가상 (Kasang)", "Kasang Kim"]
        meeting_count: 1
        ---
        ## Notes
        aliases: ["본문의 미끼는 무시"]
        """.utf8).write(to: directory.appendingPathComponent("profile.md"))

        let people = try store.listPeople(records: [])
        let person = try #require(people.first { $0.name == "김가상" })
        #expect(person.aliases == ["김가상 (Kasang)", "Kasang Kim"])

        // Candidate matching answers to the primary name or any alias,
        // case-insensitively; search matches alias substrings.
        #expect(person.answersTo("kasang kim"))
        #expect(person.answersTo("김가상"))
        #expect(!person.answersTo("다른사람"))
        #expect(person.matches(query: "Kasang"))
        #expect(!person.matches(query: "미끼"))
    }

    @Test
    func confirmationPayloadCarriesTheAliasForProfileAccumulation() throws {
        let resolution = LocalSpeakerResolution(action: "match", name: "김가상", alias: "김가상 (Kasang)")
        let data = try JSONEncoder().encode(["SPEAKER_00": resolution])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [String: String]])
        #expect(object["SPEAKER_00"]?["alias"] == "김가상 (Kasang)")
        #expect(object["SPEAKER_00"]?["name"] == "김가상")
    }
}
