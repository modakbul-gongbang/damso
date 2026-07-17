import Foundation

enum DateCoding {
    private static func makeFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    static func configure(_ encoder: JSONEncoder) {
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeFormatter().string(from: date))
        }
    }

    static func configure(_ decoder: JSONDecoder) {
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = makeFormatter().date(from: text) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected an ISO 8601 date.")
            }
            return date
        }
    }
}

enum MeetingSource: String, Codable, CaseIterable, Sendable {
    case local
    case plaud
}

enum ProcessingStage: String, Codable, CaseIterable, Sendable {
    case captured
    case queued
    case transcribing
    case speakerReview
    case summarizing
    case complete
    case partial
    case failed
    case quarantined

    var isTerminal: Bool {
        switch self {
        case .complete, .partial, .failed, .quarantined:
            true
        default:
            false
        }
    }
}

struct MeetingHints: Codable, Equatable, Sendable {
    var participants: [String]
    var topic: String?
    var domainTerms: [String]
    var numSpeakers: Int?

    static let empty = MeetingHints(participants: [], topic: nil, domainTerms: [], numSpeakers: nil)
}

struct TranscriptSegment: Codable, Equatable, Sendable {
    var speaker: String
    var startSeconds: Double
    var endSeconds: Double
    var text: String
}

struct StructuredSummary: Codable, Equatable, Sendable {
    var oneLine: String
    var keyDiscussion: [String]
    var actionItems: [String]
    var roleHints: [String: String]
    var topicSummary: String
}

enum SpeakerResolutionAction: String, Codable, Sendable {
    case match
    case new
    case me
    case skip
}

enum PersonNoteStatus: String, Codable, Sendable {
    case proposed
    case accepted
    case rejected
}

/// An agent-proposed durable fact about a named participant. Proposals stay
/// in the meeting record until the user accepts (writing to the profile) or
/// rejects them; the profile itself is never changed by a proposal.
struct PersonNoteProposal: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var note: String
    var status: PersonNoteStatus

    var id: String { "\(name)|\(note)" }
}

/// Composes the canonical 'YYYYMMDDHH-title' display title from the agent
/// title and the recording start in the local calendar.
enum MeetingTitleComposer {
    static func compose(agentTitle: String, createdAt: Date, calendar: Calendar = .current) -> String {
        let cleaned = agentTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: createdAt)
        let stamp = String(format: "%04d%02d%02d%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0, components.hour ?? 0)
        guard !cleaned.isEmpty else { return stamp }
        return "\(stamp)-\(cleaned)"
    }

    static func hasComposedPrefix(_ title: String) -> Bool {
        let prefix = title.prefix(10)
        return prefix.count == 10 && prefix.allSatisfy(\.isNumber)
    }
}

struct SpeakerResolution: Codable, Equatable, Sendable {
    var speaker: String
    var action: SpeakerResolutionAction
    var personName: String?
    /// The captured participant display name behind this confirmation, when
    /// one exists; it accumulates on the profile as an alias (R6, R9).
    var alias: String?
}

/// User-authored corrections remain distinct from original processing output.
/// This keeps retry and reprocessing decisions auditable without destroying the
/// raw local result that produced the displayed meeting detail.
struct MeetingCorrections: Codable, Equatable, Sendable {
    var title: String?
    var transcript: [TranscriptSegment]?
    var summary: StructuredSummary?
}

struct MeetingRecord: Codable, Identifiable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var stem: String
    var source: MeetingSource
    var title: String
    var createdAt: Date
    var durationSeconds: Double?
    var stage: ProcessingStage
    var hints: MeetingHints
    var completedStages: [ProcessingStage]
    var lastErrorCode: String?
    var originalAudioFile: String?
    var transcript: [TranscriptSegment]?
    var summary: StructuredSummary?
    var resolutions: [SpeakerResolution]
    var corrections: MeetingCorrections?
    var personNotes: [PersonNoteProposal]?

    init(
        id: UUID = UUID(),
        stem: String,
        source: MeetingSource,
        title: String,
        createdAt: Date = .now,
        durationSeconds: Double? = nil,
        stage: ProcessingStage = .captured,
        hints: MeetingHints = .empty,
        completedStages: [ProcessingStage] = [],
        lastErrorCode: String? = nil,
        originalAudioFile: String? = nil,
        transcript: [TranscriptSegment]? = nil,
        summary: StructuredSummary? = nil,
        resolutions: [SpeakerResolution] = [],
        corrections: MeetingCorrections? = nil,
        personNotes: [PersonNoteProposal]? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.stem = stem
        self.source = source
        self.title = title
        self.createdAt = Date(timeIntervalSince1970: (createdAt.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        self.durationSeconds = durationSeconds
        self.stage = stage
        self.hints = hints
        self.completedStages = completedStages
        self.lastErrorCode = lastErrorCode
        self.originalAudioFile = originalAudioFile
        self.transcript = transcript
        self.summary = summary
        self.resolutions = resolutions
        self.corrections = corrections
        self.personNotes = personNotes
    }
}

struct MeetingDraft: Sendable {
    var stem: String
    var source: MeetingSource
    var title: String
    var hints: MeetingHints

    init(stem: String, source: MeetingSource, title: String, hints: MeetingHints = .empty) {
        self.stem = stem
        self.source = source
        self.title = title
        self.hints = hints
    }
}
