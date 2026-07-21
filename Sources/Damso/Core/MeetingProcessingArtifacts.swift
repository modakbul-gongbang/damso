import Foundation

struct SpeakerExcerpt: Codable, Equatable, Identifiable, Sendable {
    var startSeconds: Double
    var endSeconds: Double
    var text: String

    var id: String { "\(startSeconds)-\(endSeconds)-\(text)" }

    enum CodingKeys: String, CodingKey {
        case startSeconds = "start"
        case endSeconds = "end"
        case text
    }
}

struct SpeakerCandidate: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var voiceScore: Double

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case voiceScore = "voice_score"
    }
}

struct SpeakerProposal: Equatable, Identifiable, Sendable {
    var speaker: String
    var totalSeconds: Double
    var segmentCount: Int
    var excerpts: [SpeakerExcerpt]
    var candidates: [SpeakerCandidate]
    /// Display names captured live into participants.json, offered as
    /// additional candidates beside the voice matches (R6). Empty when the
    /// meeting has no participants.json.
    var participantCandidates: [String] = []
    /// The active-speaker time-axis majority winner for this diarization
    /// speaker: the automatic first proposal. Confirmation still requires the
    /// user's click (R6, AC10).
    var suggestedParticipant: String? = nil

    var id: String { speaker }
}

/// Overlays diarization segments with the captured active-speaker samples and
/// picks, per diarization speaker, the participant who was the indicated
/// active speaker for the most samples (time-axis majority vote, D-18).
enum ActiveSpeakerMajorityVote {
    static func suggestions(segments: [TranscriptSegment], participants: [MeetingParticipantRecord]) -> [String: String] {
        guard !segments.isEmpty else { return [:] }
        // votes[speaker][participantName] = sample count
        var votes: [String: [String: Int]] = [:]
        for participant in participants {
            for offset in participant.speakingSamples ?? [] {
                guard let segment = segments.first(where: { offset >= $0.startSeconds && offset < $0.endSeconds }) else { continue }
                votes[segment.speaker, default: [:]][participant.name, default: 0] += 1
            }
        }
        var winners: [String: String] = [:]
        for (speaker, counts) in votes {
            // Deterministic tie-break by name keeps the proposal stable
            // across reloads.
            if let winner = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
                winners[speaker] = winner.key
            }
        }
        return winners
    }
}

struct MeetingProcessingArtifacts: Equatable, Sendable {
    var transcript: [TranscriptSegment]
    var proposals: [SpeakerProposal]
    /// Per-segment-index replacements from the agent cleanup overlay. The
    /// original transcript files are never rewritten; an empty map means the
    /// overlay is absent or made no changes.
    var cleanedTexts: [Int: String]

    static let empty = MeetingProcessingArtifacts(transcript: [], proposals: [], cleanedTexts: [:])
}

private struct StoredTranscript: Decodable {
    var generationID: String?
    var segments: [StoredTranscriptSegment]

    enum CodingKeys: String, CodingKey {
        case generationID = "generation_id"
        case segments
    }
}

private struct StoredTranscriptSegment: Decodable {
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

private struct StoredIdentification: Decodable {
    var generationID: String?
    var proposals: [String: StoredSpeakerProposal]

    enum CodingKeys: String, CodingKey {
        case generationID = "generation_id"
        case proposals
    }
}

private struct StoredPhaseOneCompletion: Decodable {
    var generationID: String

    enum CodingKeys: String, CodingKey {
        case generationID = "generation_id"
    }
}

private struct StoredCleanupOverlay: Decodable {
    struct Correction: Decodable {
        var index: Int
        var text: String
    }

    var corrections: [Correction]
}

private struct StoredSpeakerProposal: Decodable {
    // Legacy imported identification.json carries only `candidates` (and a
    // `hints` field the app ignores); records produced by the current
    // pipeline also carry total_seconds/segment_count/excerpts. All three
    // are optional here so an older artifact still decodes; the reader fills
    // the missing totals from the transcript segments.
    var totalSeconds: Double?
    var segmentCount: Int?
    var excerpts: [SpeakerExcerpt]?
    var candidates: [SpeakerCandidate]?

    enum CodingKeys: String, CodingKey {
        case totalSeconds = "total_seconds"
        case segmentCount = "segment_count"
        case excerpts
        case candidates
    }
}

private struct StoredSummary: Decodable {
    var title: String?
    var roleHint: String
    var topicSummary: String
    var oneLineSummary: String
    var keyPoints: [String]
    var actionItems: [StoredSummaryAction]
    var personNotes: [StoredPersonNote]?

    enum CodingKeys: String, CodingKey {
        case title
        case roleHint = "role_hint"
        case topicSummary = "topic_summary"
        case oneLineSummary = "one_line_summary"
        case keyPoints = "key_points"
        case actionItems = "action_items"
        case personNotes = "person_notes"
    }
}

private struct StoredSummaryAction: Decodable {
    var task: String
    var owner: String?
    var due: String?
    var dueDate: String?

    enum CodingKeys: String, CodingKey {
        case task
        case owner
        case due
        case dueDate = "due_date"
    }
}

private struct StoredPersonNote: Decodable {
    var name: String
    var note: String
}

/// The bounded artifact produced by the agent boundary: the structured
/// summary plus the short agent title and person-note proposals.
struct StoredSummaryArtifact: Equatable, Sendable {
    var summary: StructuredSummary
    var agentTitle: String?
    var personNotes: [PersonNoteProposal]
}

extension MeetingStore {
    /// Reads only already-produced local phase-one artifacts from a canonical
    /// record. The parsing layer never starts a process or reaches outside the
    /// selected record directory.
    func processingArtifacts(stem: String) throws -> MeetingProcessingArtifacts {
        let directory = CanonicalStoreLayout(root: rootURL).recordDirectory(stem: stem)
        let rawTranscript = directory.appendingPathComponent("transcript.raw.json")
        guard FileManager.default.fileExists(atPath: rawTranscript.path) else {
            return .empty
        }

        let decoder = JSONDecoder()
        let transcript = try decoder.decode(StoredTranscript.self, from: Data(contentsOf: rawTranscript))
        let segments = transcript.segments.map {
            TranscriptSegment(speaker: $0.speaker, startSeconds: $0.start, endSeconds: $0.end, text: $0.text)
        }
        let cleanedTexts = cleanupOverlay(directory: directory, segmentCount: segments.count)
        let identificationURL = directory.appendingPathComponent("identification.json")
        guard FileManager.default.fileExists(atPath: identificationURL.path) else {
            return MeetingProcessingArtifacts(transcript: segments, proposals: [], cleanedTexts: cleanedTexts)
        }
        // A malformed or unreadable identification.json must never hide the
        // transcript that already decoded: fall back to no proposals.
        guard let identification = try? decoder.decode(StoredIdentification.self, from: Data(contentsOf: identificationURL)) else {
            return MeetingProcessingArtifacts(transcript: segments, proposals: [], cleanedTexts: cleanedTexts)
        }
        // Per-speaker transcript totals, used when the artifact omits them.
        var segmentsBySpeaker: [String: (seconds: Double, count: Int)] = [:]
        for segment in segments {
            var totals = segmentsBySpeaker[segment.speaker] ?? (0, 0)
            totals.seconds += max(0, segment.endSeconds - segment.startSeconds)
            totals.count += 1
            segmentsBySpeaker[segment.speaker] = totals
        }
        // Captured participants (when the meeting has participants.json)
        // extend the manual review: names become extra candidates, and
        // active-speaker samples produce the automatic first proposal. A
        // missing or empty file leaves the flow untouched (R5, R6).
        let participants = MeetingParticipantsFile.read(from: directory.appendingPathComponent("participants.json"))?.participants ?? []
        let suggestions = ActiveSpeakerMajorityVote.suggestions(segments: segments, participants: participants)
        let proposals = identification.proposals.map { (speaker: String, proposal: StoredSpeakerProposal) -> SpeakerProposal in
            let fallback = segmentsBySpeaker[speaker] ?? (0, 0)
            let voiceCandidates = (proposal.candidates ?? [])
                .filter { $0.voiceScore >= 0.25 }
                .sorted { $0.voiceScore > $1.voiceScore }
            let voiceNames = Set(voiceCandidates.map { LocalPersonProfile.foldingKey($0.name) })
            var participantNames = participants.map(\.name).filter { !voiceNames.contains(LocalPersonProfile.foldingKey($0)) }
            // The majority-vote winner leads the participant candidates.
            if let suggested = suggestions[speaker], let index = participantNames.firstIndex(of: suggested), index != 0 {
                participantNames.remove(at: index)
                participantNames.insert(suggested, at: 0)
            }
            return SpeakerProposal(
                speaker: speaker,
                totalSeconds: proposal.totalSeconds ?? fallback.seconds,
                segmentCount: proposal.segmentCount ?? fallback.count,
                excerpts: proposal.excerpts ?? [],
                // Older identification artifacts may carry unsorted or
                // noise-level candidates; keep the manual review honest by
                // showing only meaningful matches, strongest first.
                candidates: voiceCandidates,
                participantCandidates: participantNames,
                suggestedParticipant: suggestions[speaker]
            )
        }.sorted { $0.speaker.localizedStandardCompare($1.speaker) == .orderedAscending }
        return MeetingProcessingArtifacts(transcript: segments, proposals: proposals, cleanedTexts: cleanedTexts)
    }

    /// Whether phase-one transcription already produced its raw transcript for
    /// this record. Used to keep imported/resumed processing idempotent so a
    /// record that already has a transcript is never transcribed again.
    func hasPhaseOneTranscript(stem: String) -> Bool {
        let raw = CanonicalStoreLayout(root: rootURL).recordDirectory(stem: stem).appendingPathComponent("transcript.raw.json")
        return FileManager.default.fileExists(atPath: raw.path)
    }

    /// Crash recovery may skip phase one only after both artifacts required by
    /// speaker review are present, decodable, and describe the same speakers.
    /// A transcript can reach disk immediately before identification.json, so
    /// transcript existence alone is not a completion marker.
    func hasCompletePhaseOneReviewArtifacts(stem: String) -> Bool {
        let directory = CanonicalStoreLayout(root: rootURL).recordDirectory(stem: stem)
        let transcriptURL = directory.appendingPathComponent("transcript.raw.json")
        let identificationURL = directory.appendingPathComponent("identification.json")
        let completionURL = directory.appendingPathComponent("phase-one.complete.json")
        let inProgressURL = directory.appendingPathComponent("phase-one.in-progress.json")
        let safeRegularFile: (URL) -> Bool = { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        let inProgressValues = try? inProgressURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard inProgressValues?.isRegularFile != true, inProgressValues?.isSymbolicLink != true else {
            return false
        }
        guard safeRegularFile(transcriptURL),
              safeRegularFile(identificationURL),
              let transcriptData = try? Data(contentsOf: transcriptURL),
              let identificationData = try? Data(contentsOf: identificationURL),
              let transcript = try? JSONDecoder().decode(StoredTranscript.self, from: transcriptData),
              let identification = try? JSONDecoder().decode(StoredIdentification.self, from: identificationData) else {
            return false
        }
        guard Set(transcript.segments.map(\.speaker)) == Set(identification.proposals.keys) else {
            return false
        }
        switch (transcript.generationID, identification.generationID) {
        case (nil, nil):
            return true
        case (.some(let transcriptGeneration), .some(let identificationGeneration))
            where !transcriptGeneration.isEmpty && transcriptGeneration == identificationGeneration:
            guard safeRegularFile(completionURL),
                  let completionData = try? Data(contentsOf: completionURL),
                  let completion = try? JSONDecoder().decode(StoredPhaseOneCompletion.self, from: completionData) else {
                return false
            }
            return completion.generationID == transcriptGeneration
        default:
            return false
        }
    }

    private func speakerHintsURL(stem: String) -> URL {
        CanonicalStoreLayout(root: rootURL).recordDirectory(stem: stem).appendingPathComponent("speaker_hints.json")
    }

    /// The persisted, transcript-read speaker hints for this record, grouped by
    /// diarization speaker. Empty when the agent has not run for it yet.
    func cachedSpeakerSuggestions(stem: String) -> [String: [SpeakerSuggestion]] {
        guard let data = try? Data(contentsOf: speakerHintsURL(stem: stem)),
              let stored = try? JSONDecoder().decode(StoredSpeakerHints.self, from: data) else { return [:] }
        return Dictionary(grouping: stored.suggestions, by: \.speaker)
    }

    func hasCachedSpeakerSuggestions(stem: String) -> Bool {
        FileManager.default.fileExists(atPath: speakerHintsURL(stem: stem).path)
    }

    /// Persists the agent's speaker hints so later opens are instant. Called
    /// only after a successful run, including an empty result (which records
    /// that the agent ran and found nothing, so it is not retried every open).
    func writeSpeakerSuggestions(_ suggestions: [SpeakerSuggestion], stem: String) {
        let payload = StoredSpeakerHints(suggestions: suggestions)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: speakerHintsURL(stem: stem), options: .atomic)
    }

    /// Whether the agent cleanup overlay has been produced for this record.
    /// Its presence (even with zero corrections) means the cleanup pass ran.
    func hasCleanupOverlay(stem: String) -> Bool {
        let overlay = CanonicalStoreLayout(root: rootURL).recordDirectory(stem: stem).appendingPathComponent("transcript.cleaned.json")
        return FileManager.default.fileExists(atPath: overlay.path)
    }

    private func cleanupOverlay(directory: URL, segmentCount: Int) -> [Int: String] {
        let overlayURL = directory.appendingPathComponent("transcript.cleaned.json")
        guard let data = try? Data(contentsOf: overlayURL),
              let overlay = try? JSONDecoder().decode(StoredCleanupOverlay.self, from: data) else {
            return [:]
        }
        var cleaned: [Int: String] = [:]
        for correction in overlay.corrections where correction.index >= 0 && correction.index < segmentCount {
            cleaned[correction.index] = correction.text
        }
        return cleaned
    }

    /// Reads only the bounded structured result previously saved by the local
    /// summary boundary. Missing summaries are normal and do not imply that the
    /// original transcript or local speaker work failed.
    func storedSummary(stem: String) throws -> StructuredSummary? {
        try storedSummaryArtifact(stem: stem)?.summary
    }

    func storedSummaryArtifact(stem: String) throws -> StoredSummaryArtifact? {
        let summaryURL = CanonicalStoreLayout(root: rootURL).recordDirectory(stem: stem).appendingPathComponent("summary.json")
        guard FileManager.default.fileExists(atPath: summaryURL.path) else { return nil }
        let summary = try JSONDecoder().decode(StoredSummary.self, from: Data(contentsOf: summaryURL))
        let actionItems = summary.actionItems.map { action in
            var components = [action.task]
            if let owner = action.owner, !owner.isEmpty { components.append("Owner: \(owner)") }
            if let due = action.due, !due.isEmpty { components.append("Due: \(due)") }
            return components.joined(separator: " · ")
        }
        let actions = summary.actionItems.map { action in
            SummaryActionItem(task: action.task, owner: action.owner, due: action.due, dueDate: action.dueDate)
        }
        let roleHints = summary.roleHint.isEmpty ? [:] : ["Meeting role": summary.roleHint]
        let structured = StructuredSummary(
            oneLine: summary.oneLineSummary,
            keyDiscussion: summary.keyPoints,
            actionItems: actionItems,
            roleHints: roleHints,
            topicSummary: summary.topicSummary,
            actions: actions
        )
        let notes = (summary.personNotes ?? []).compactMap { note -> PersonNoteProposal? in
            let name = note.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = note.note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !text.isEmpty else { return nil }
            return PersonNoteProposal(name: name, note: text, status: .proposed)
        }
        return StoredSummaryArtifact(summary: structured, agentTitle: summary.title, personNotes: notes)
    }
}
