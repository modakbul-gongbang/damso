import Foundation

/// One line of a person's `## Notes` section, parsed for display.
///
/// The section is a plain-Markdown log a human also edits by hand, so the UI
/// cannot render it verbatim: authoring comments and bullet syntax leaked
/// into the profile screen as literal text (`<!-- ... -->`, `- (2026-08-15)
/// ...`). Parsing here keeps the file human-owned while the screen shows the
/// facts.
struct ProfileNoteEntry: Identifiable, Equatable, Sendable {
    /// The meeting date the note was learned on, when the line carries one.
    /// Hand-written lines usually do not.
    let date: String?
    let text: String

    var id: String { "\(date ?? "")|\(text)" }
}

struct ProfileNoteDigest: Equatable, Sendable {
    /// Lines the user wrote themselves (no date prefix): their own
    /// description of the person, shown as prose above the log.
    let freeform: [String]
    /// Dated lines the summary pipeline appended, newest first - a profile
    /// grows for years, so the oldest fact should not be the first one read.
    let entries: [ProfileNoteEntry]

    var isEmpty: Bool { freeform.isEmpty && entries.isEmpty }

    /// Everything as plain text, for "copy" and for the meeting-side callers
    /// that still want one string.
    var plainText: String {
        (freeform + entries.map { entry in
            entry.date.map { "(\($0)) \(entry.text)" } ?? entry.text
        }).joined(separator: "\n")
    }

    static let empty = ProfileNoteDigest(freeform: [], entries: [])

    private static let commentPattern = try? NSRegularExpression(pattern: "<!--.*?-->", options: [.dotMatchesLineSeparators])
    private static let bulletPattern = try? NSRegularExpression(pattern: "\\A[-*+]\\s+")
    private static let datePattern = try? NSRegularExpression(pattern: "\\A\\((\\d{4}-\\d{2}-\\d{2})\\)\\s*")

    /// Parses a raw `## Notes` body. Anything that is not recognized as
    /// syntax is preserved as text rather than dropped: this is the user's
    /// own file, and silently swallowing a line they wrote would be worse
    /// than showing it plainly.
    static func parse(_ raw: String?) -> ProfileNoteDigest {
        guard let raw, !raw.isEmpty else { return .empty }
        let withoutComments = strip(commentPattern, from: raw)
        var freeform: [String] = []
        var entries: [ProfileNoteEntry] = []
        for line in withoutComments.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "-" }) { continue }
            let body = strip(bulletPattern, from: trimmed).trimmingCharacters(in: .whitespaces)
            if body.isEmpty { continue }
            if let date = leadingDate(in: body) {
                entries.append(ProfileNoteEntry(date: date, text: strip(datePattern, from: body).trimmingCharacters(in: .whitespaces)))
            } else {
                freeform.append(body)
            }
        }
        return ProfileNoteDigest(
            freeform: freeform,
            entries: entries.enumerated()
                .sorted { left, right in
                    // Stable newest-first: same-day notes keep file order.
                    if left.element.date == right.element.date { return left.offset < right.offset }
                    return (left.element.date ?? "") > (right.element.date ?? "")
                }
                .map(\.element)
        )
    }

    private static func leadingDate(in text: String) -> String? {
        guard let datePattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = datePattern.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func strip(_ pattern: NSRegularExpression?, from text: String) -> String {
        guard let pattern else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }
}
