import Foundation

/// One person in the local library, aggregated from profile directories and
/// meeting confirmations. Identity is the folded display name so the same
/// person matches across case and diacritic variants.
struct LocalPersonProfile: Identifiable, Equatable, Sendable {
    var name: String
    var meetingCount: Int
    var lastMeetingAt: Date?
    var hasVoiceProfile: Bool
    var aliases: [String] = []

    var id: String { Self.foldingKey(name) }

    static func foldingKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    /// True when this profile owns the given display name, either as its own
    /// name or as an accumulated alias (folded exact match).
    func answersTo(_ candidate: String) -> Bool {
        let key = Self.foldingKey(candidate)
        if Self.foldingKey(name) == key { return true }
        return aliases.contains { Self.foldingKey($0) == key }
    }

    /// Case- and diacritic-insensitive search over the display name and every
    /// alias, so a captured participant name finds its merged profile.
    func matches(query: String) -> Bool {
        let key = Self.foldingKey(query)
        if Self.foldingKey(name).contains(key) { return true }
        return aliases.contains { Self.foldingKey($0).contains(key) }
    }
}
