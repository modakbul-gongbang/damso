import Foundation

enum SummaryAgent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var executableName: String { rawValue }
}

enum SummaryLanguage: String, Codable, CaseIterable, Sendable {
    case korean = "ko"
    case english = "en"
}

struct LocalSummaryRequest: Encodable, Sendable {
    let recordingDirectory: String
    let agent: String
    let language: String
    let meetingDate: String?

    enum CodingKeys: String, CodingKey {
        case recordingDirectory = "recording_directory"
        case agent
        case language
        case meetingDate = "meeting_date"
    }

    init(recordingDirectory: String, agent: SummaryAgent, language: SummaryLanguage, meetingDate: String? = nil) {
        self.recordingDirectory = recordingDirectory
        self.agent = agent.rawValue
        self.language = language.rawValue
        self.meetingDate = meetingDate
    }

    /// The due_date anchor uses the user's local calendar day, not UTC: a
    /// meeting recorded at 00:30 KST belongs to that local day and relative
    /// phrases ("내일") resolve against it.
    static func localMeetingDate(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct LocalSummaryResult: Decodable, Equatable, Sendable {
    let ok: Bool
    let status: String?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case status
        case errorCode = "error_code"
    }
}

enum LocalSummaryCommandError: Error, Equatable {
    case requestEncoding
    case launchFailed
    case failed
    case invalidResponse
    case oversizedResponse
}
