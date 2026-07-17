import Foundation

enum ProfileMergeError: Error, Equatable {
    /// Merging a profile into itself (same folded identity) is blocked.
    case invalidSelection
    case absorbedProfileMissing
    case archiveFailed
    case transferFailed
}

/// What one merge did, for the UI confirmation and for recovery guidance.
struct ProfileMergeOutcome: Equatable, Sendable {
    var primaryName: String
    var absorbedName: String
    /// Where the absorbed profile folder was preserved before any transfer.
    var archiveDirectory: URL
}

extension MeetingStore {
    /// Full profile merge (R7): archive the absorbed profile folder first,
    /// then transfer meeting history, voice embedding, notes, and aliases
    /// into the primary profile, then remove the absorbed folder. Files stay
    /// recoverable at every step: the archive copy exists before anything is
    /// modified, so a failure mid-way never loses data.
    ///
    /// The index rebuild is the caller's follow-up (it is deterministic and
    /// derived from files).
    func mergeProfiles(primaryName: String, absorbedName: String) throws -> ProfileMergeOutcome {
        let primary = primaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let absorbed = absorbedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primary.isEmpty, !absorbed.isEmpty,
              LocalPersonProfile.foldingKey(primary) != LocalPersonProfile.foldingKey(absorbed) else {
            throw ProfileMergeError.invalidSelection
        }
        let layout = CanonicalStoreLayout(root: rootURL)
        let absorbedDirectory = layout.peoples.appendingPathComponent(Self.profileSlug(absorbed), isDirectory: true)
        let primaryDirectory = layout.peoples.appendingPathComponent(Self.profileSlug(primary), isDirectory: true)
        let absorbedProfileExists = FileManager.default.fileExists(atPath: absorbedDirectory.appendingPathComponent("profile.md").path)
        guard absorbedProfileExists else { throw ProfileMergeError.absorbedProfileMissing }

        // 1. Archive first: the absorbed folder is copied verbatim under
        //    peoples/archive/ before any transfer touches it (D-22). Restore
        //    is "move the folder back + rebuild the index".
        let archiveRoot = layout.peoples.appendingPathComponent("archive", isDirectory: true)
        var archiveDestination = archiveRoot.appendingPathComponent(absorbedDirectory.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: archiveDestination.path) {
            let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
            archiveDestination = archiveRoot.appendingPathComponent("\(absorbedDirectory.lastPathComponent)-\(stamp)", isDirectory: true)
        }
        do {
            try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: absorbedDirectory, to: archiveDestination)
        } catch {
            throw ProfileMergeError.archiveFailed
        }

        // 2. Transfer into the primary profile.
        do {
            let absorbedProfile = ProfileFrontmatterFile(directory: absorbedDirectory)
            var primaryProfile = ProfileFrontmatterFile(directory: primaryDirectory)
            primaryProfile.ensureExists(name: primary)

            var aliases = primaryProfile.stringArray("aliases")
            for alias in [absorbed] + absorbedProfile.stringArray("aliases")
            where alias != primary && !aliases.contains(alias) {
                aliases.append(alias)
            }
            primaryProfile.setJSON("aliases", aliases)

            var stems = primaryProfile.stringArray("meeting_stems")
            for stem in absorbedProfile.stringArray("meeting_stems") where !stems.contains(stem) {
                stems.append(stem)
            }
            if !stems.isEmpty {
                primaryProfile.setJSON("meeting_stems", stems.sorted())
                primaryProfile.setJSON("meeting_count", max(stems.count, primaryProfile.int("meeting_count") ?? 0))
            } else {
                let combined = (primaryProfile.int("meeting_count") ?? 0) + (absorbedProfile.int("meeting_count") ?? 0)
                if combined > 0 { primaryProfile.setJSON("meeting_count", combined) }
            }

            if let primaryFirst = primaryProfile.string("first_seen"), let absorbedFirst = absorbedProfile.string("first_seen") {
                primaryProfile.setJSON("first_seen", min(primaryFirst, absorbedFirst))
            } else if let absorbedFirst = absorbedProfile.string("first_seen") {
                primaryProfile.setJSON("first_seen", absorbedFirst)
            }
            if let primaryLast = primaryProfile.string("last_seen"), let absorbedLast = absorbedProfile.string("last_seen") {
                primaryProfile.setJSON("last_seen", max(primaryLast, absorbedLast))
            } else if let absorbedLast = absorbedProfile.string("last_seen") {
                primaryProfile.setJSON("last_seen", absorbedLast)
            }
            if primaryProfile.string("email") == nil, let email = absorbedProfile.string("email") {
                primaryProfile.setJSON("email", email)
            }

            // Voice embedding: transferred when the primary has none; when
            // both profiles carry one, the primary's stays authoritative and
            // the absorbed embedding remains available in the archive.
            let primaryVoice = primaryDirectory.appendingPathComponent("voice.npy")
            let absorbedVoice = absorbedDirectory.appendingPathComponent("voice.npy")
            if !FileManager.default.fileExists(atPath: primaryVoice.path),
               FileManager.default.fileExists(atPath: absorbedVoice.path) {
                try FileManager.default.copyItem(at: absorbedVoice, to: primaryVoice)
                if let model = absorbedProfile.string("voice_model") {
                    primaryProfile.setJSON("voice_model", model)
                }
                if let samples = absorbedProfile.int("voice_samples") {
                    primaryProfile.setJSON("voice_samples", samples)
                }
            }

            if let notes = absorbedProfile.notesSection(), !notes.isEmpty {
                primaryProfile.appendNotes(notes.map { "\($0) [\(absorbed)]" })
            }

            try primaryProfile.save()

            // 3. Remove the absorbed folder only after the transfer landed.
            try FileManager.default.removeItem(at: absorbedDirectory)
        } catch {
            // The archive copy and the untouched absorbed folder both still
            // exist; surface the failure without losing anything.
            throw ProfileMergeError.transferFailed
        }

        return ProfileMergeOutcome(primaryName: primary, absorbedName: absorbed, archiveDirectory: archiveDestination)
    }
}

/// Minimal frontmatter editor for profile.md matching the python writer's
/// line format (`key: <json>` per line). Unknown fields and the body are
/// preserved verbatim; only explicitly set keys change.
private struct ProfileFrontmatterFile {
    let directory: URL
    private var fields: [(key: String, raw: String)] = []
    private var body: String = ""
    private var exists = false

    init(directory: URL) {
        self.directory = directory
        let url = directory.appendingPathComponent("profile.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("---\n"),
              let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else {
            return
        }
        exists = true
        let frontmatter = text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound]
        for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let separator = line.range(of: ": ") else { continue }
            fields.append((String(line[..<separator.lowerBound]), String(line[separator.upperBound...])))
        }
        body = String(text[end.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\n")).isEmpty
            ? ""
            : String(text[end.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
    }

    mutating func ensureExists(name: String) {
        guard !exists else { return }
        exists = true
        let today = ISO8601DateFormatter().string(from: .now).prefix(10)
        fields = [
            ("name", jsonString(name)),
            ("aliases", "[]"),
            ("first_seen", jsonString(String(today))),
            ("last_seen", jsonString(String(today))),
            ("meeting_count", "0"),
            ("voice_samples", "0"),
        ]
        body = "## Description\n\n## Meetings\n\n## Notes\n"
    }

    func string(_ key: String) -> String? {
        guard let raw = fields.first(where: { $0.key == key })?.raw,
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: data) else { return nil }
        return value
    }

    func int(_ key: String) -> Int? {
        guard let raw = fields.first(where: { $0.key == key })?.raw else { return nil }
        return Int(raw.trimmingCharacters(in: .whitespaces))
    }

    func stringArray(_ key: String) -> [String] {
        guard let raw = fields.first(where: { $0.key == key })?.raw,
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return value
    }

    mutating func setJSON(_ key: String, _ value: some Encodable) {
        // Match the python writer's json.dumps output ("/" stays unescaped).
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let raw = String(data: data, encoding: .utf8) else { return }
        if let index = fields.firstIndex(where: { $0.key == key }) {
            fields[index].raw = raw
        } else {
            fields.append((key, raw))
        }
    }

    /// Lines of the absorbed profile's Notes section (without the heading).
    func notesSection() -> [String]? {
        guard let range = body.range(of: "## Notes") else { return nil }
        var notes = String(body[range.upperBound...])
        if let next = notes.range(of: "\n## ") {
            notes = String(notes[..<next.lowerBound])
        }
        let lines = notes.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return lines.isEmpty ? nil : lines
    }

    mutating func appendNotes(_ lines: [String]) {
        let block = lines.joined(separator: "\n")
        if let range = body.range(of: "## Notes") {
            let head = String(body[..<range.lowerBound])
            var tail = String(body[range.upperBound...])
            if let next = tail.range(of: "\n## ") {
                let notes = String(tail[..<next.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                let rest = String(tail[next.lowerBound...])
                body = head + "## Notes\n" + (notes.isEmpty ? "" : notes + "\n") + block + rest
            } else {
                tail = tail.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                body = head + "## Notes\n" + (tail.isEmpty ? "" : tail + "\n") + block + "\n"
            }
        } else {
            body = body.isEmpty ? "## Notes\n\(block)\n" : body.trimmingCharacters(in: CharacterSet(charactersIn: "\n")) + "\n\n## Notes\n\(block)\n"
        }
    }

    private func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let raw = String(data: data, encoding: .utf8) else { return "\"\"" }
        return raw
    }

    func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lines = fields.map { "\($0.key): \($0.raw)" }
        let content = "---\n" + lines.joined(separator: "\n") + "\n---\n" + (body.hasPrefix("\n") ? String(body.dropFirst()) : body)
        let url = directory.appendingPathComponent("profile.md")
        try Data(content.utf8).write(to: url, options: .atomic)
    }
}
