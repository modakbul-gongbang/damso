import Foundation

struct OperationEvent: Codable, Equatable, Sendable {
    enum Level: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    var timestamp: Date
    var level: Level
    var code: String
    var meetingStem: String?
    var message: String
    var nextAction: String?
}

final class OperationLedger {
    private let fileURL: URL
    private let maximumEntries: Int
    private let retention: TimeInterval
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL, maximumEntries: Int = 500, retention: TimeInterval = 60 * 60 * 24 * 30) {
        self.fileURL = fileURL
        self.maximumEntries = maximumEntries
        self.retention = retention
        DateCoding.configure(encoder)
        encoder.outputFormatting = [.sortedKeys]
        DateCoding.configure(decoder)
    }

    func append(_ event: OperationEvent) throws {
        var events = try read()
        events.append(redacted(event))
        let cutoff = Date.now.addingTimeInterval(-retention)
        events = events.filter { $0.timestamp >= cutoff }
        events = Array(events.suffix(maximumEntries))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(events).write(to: fileURL, options: .atomic)
    }

    func read() throws -> [OperationEvent] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([OperationEvent].self, from: Data(contentsOf: fileURL))
    }

    func redacted(_ event: OperationEvent) -> OperationEvent {
        var result = event
        result.message = Redactor.redact(event.message)
        result.nextAction = event.nextAction.map(Redactor.redact)
        return result
    }

    /// Diagnostics exports contain operational codes and redacted next actions,
    /// never a meeting identifier, transcript, audio location, or profile path.
    func exportRedacted() throws -> String {
        let exported = try read().map { event -> OperationEvent in
            var redacted = self.redacted(event)
            redacted.meetingStem = nil
            return redacted
        }
        return String(data: try encoder.encode(exported), encoding: .utf8) ?? "[]"
    }
}

enum Redactor {
    static func redact(_ text: String) -> String {
        let home = NSHomeDirectory()
        var result = text.replacingOccurrences(of: home, with: "<home>")
        let patterns: [(pattern: String, replacement: String)] = [
            ("(?i)\\b(authorization|token|cookie|session|password|api[ _-]?key)\\s*[:=]\\s*(?:bearer\\s+)?(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)", "$1=<redacted>"),
            ("(?i)\\b(bearer)\\s+(?:\\\"[^\\\"]*\\\"|'[^']*'|[^\\s,;]+)", "$1 <redacted>"),
            ("(?i)\\bsk-[a-z0-9_-]+\\b", "<redacted>"),
            ("(?i)file://[^\\s,;]+", "<file-url>"),
            ("/(?:Users|private|Volumes|var|tmp|Library)/[^\\s,;]+", "<path>")
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern.pattern,
                with: pattern.replacement,
                options: .regularExpression
            )
        }
        return result
    }
}
