import CryptoKit
import Foundation

enum StorageHealth: Equatable {
    case ready
    case unavailable(String)
    case readOnly
    case insufficientSpace(availableBytes: Int64)
    case unsupportedSchema(found: Int)
}

enum MeetingStoreError: Error, Equatable, LocalizedError {
    case unsafeRoot(StorageHealth)
    case invalidStem
    case duplicateMeeting
    case invalidArtifactName
    case unsafeArtifactType
    case corruptRecord
    case missingRecord

    var errorDescription: String? {
        switch self {
        case .unsafeRoot(let health): "Storage root is not safe: \(health)"
        case .invalidStem: "Meeting stem is invalid."
        case .duplicateMeeting: "A meeting with this stem already exists."
        case .invalidArtifactName: "Artifact names may not traverse directories."
        case .unsafeArtifactType: "A generated artifact has an unsafe file type."
        case .corruptRecord: "The meeting record is corrupt."
        case .missingRecord: "The meeting record does not exist."
        }
    }
}

enum StagedCommitRecovery: Equatable {
    case committed(stem: String)
    case quarantined(reason: String)
}

struct StoreManifest: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var createdAt: Date

    init(schemaVersion: Int = Self.currentSchemaVersion, createdAt: Date = .now) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
    }
}

struct CanonicalStoreLayout {
    let root: URL

    var manifest: URL { root.appendingPathComponent("store.json") }
    var plaudRoot: URL { root.appendingPathComponent("Plaud", isDirectory: true) }
    var recordings: URL { plaudRoot.appendingPathComponent("recordings", isDirectory: true) }
    var peoples: URL { plaudRoot.appendingPathComponent("peoples", isDirectory: true) }
    var staging: URL { root.appendingPathComponent(".staging", isDirectory: true) }
    var quarantine: URL { root.appendingPathComponent(".quarantine", isDirectory: true) }

    func recordDirectory(stem: String) -> URL {
        recordings.appendingPathComponent(stem, isDirectory: true)
    }
}

final class MeetingStore {
    static let defaultRoot: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Damso", isDirectory: true)

    private let layout: CanonicalStoreLayout
    private let fileManager: FileManager
    private let minimumFreeBytes: Int64
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL = MeetingStore.defaultRoot, minimumFreeBytes: Int64 = 256 * 1_024 * 1_024, fileManager: FileManager = .default) {
        self.layout = CanonicalStoreLayout(root: root.standardizedFileURL)
        self.fileManager = fileManager
        self.minimumFreeBytes = minimumFreeBytes
        self.encoder = JSONEncoder()
        DateCoding.configure(self.encoder)
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.decoder = JSONDecoder()
        DateCoding.configure(self.decoder)
    }

    var rootURL: URL { layout.root }

    func bootstrap() throws {
        let parent = layout.root.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: layout.root.path) {
            try fileManager.createDirectory(at: layout.root, withIntermediateDirectories: false)
        }
        guard case .ready = health() else { throw MeetingStoreError.unsafeRoot(health()) }
        for directory in [layout.recordings, layout.peoples, layout.staging, layout.quarantine] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: layout.manifest.path) {
            let manifest = try readManifest()
            guard manifest.schemaVersion == StoreManifest.currentSchemaVersion else {
                throw MeetingStoreError.unsafeRoot(.unsupportedSchema(found: manifest.schemaVersion))
            }
        } else {
            try write(StoreManifest(), to: layout.manifest)
        }
    }

    func health() -> StorageHealth {
        let root = layout.root
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            return .unavailable("The configured root is a file.")
        }

        let probeDirectory = fileManager.fileExists(atPath: root.path) ? root : root.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: probeDirectory.path) else { return .readOnly }

        do {
            let values = try probeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let available = values.volumeAvailableCapacityForImportantUsage ?? 0
            if available < minimumFreeBytes { return .insufficientSpace(availableBytes: available) }
        } catch {
            return .unavailable("Cannot inspect available storage.")
        }

        guard !fileManager.fileExists(atPath: layout.manifest.path) else {
            do {
                let manifest = try readManifest()
                if manifest.schemaVersion != StoreManifest.currentSchemaVersion {
                    return .unsupportedSchema(found: manifest.schemaVersion)
                }
            } catch {
                return .unavailable("Store manifest is unreadable.")
            }
            return .ready
        }
        return .ready
    }

    func createRecord(_ draft: MeetingDraft) throws -> MeetingRecord {
        guard isSafeStem(draft.stem) else { throw MeetingStoreError.invalidStem }
        try bootstrap()
        return MeetingRecord(stem: draft.stem, source: draft.source, title: draft.title, hints: draft.hints)
    }

    func commit(_ record: MeetingRecord, artifacts: [String: Data] = [:]) throws {
        guard isSafeStem(record.stem) else { throw MeetingStoreError.invalidStem }
        try bootstrap()
        let destination = layout.recordDirectory(stem: record.stem)
        guard !fileManager.fileExists(atPath: destination.path) else { throw MeetingStoreError.duplicateMeeting }

        let temporary = layout.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporary) }

        try write(record, to: temporary.appendingPathComponent("meeting.json"))
        for (name, data) in artifacts {
            guard isSafeArtifactName(name) else { throw MeetingStoreError.invalidArtifactName }
            try data.write(to: temporary.appendingPathComponent(name), options: .atomic)
        }
        try validateCommittedDirectory(temporary, expectedStem: record.stem)
        try fileManager.moveItem(at: temporary, to: destination)
    }

    /// Commits an externally synced meeting by moving its already-validated
    /// audio file (large downloads never pass through memory). The record and
    /// audio land in staging first and reach the canonical directory in one
    /// atomic move, so a partial import can never appear in the meeting list.
    func commitImported(_ record: MeetingRecord, movingAudioFrom audioURL: URL) throws {
        guard isSafeStem(record.stem) else { throw MeetingStoreError.invalidStem }
        let audioName = audioURL.lastPathComponent
        guard isSafeArtifactName(audioName), record.originalAudioFile == audioName else {
            throw MeetingStoreError.invalidArtifactName
        }
        try bootstrap()
        let destination = layout.recordDirectory(stem: record.stem)
        guard !fileManager.fileExists(atPath: destination.path) else { throw MeetingStoreError.duplicateMeeting }

        let temporary = layout.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: temporary) }

        try write(record, to: temporary.appendingPathComponent("meeting.json"))
        try fileManager.moveItem(at: audioURL, to: temporary.appendingPathComponent(audioName))
        try validateCommittedDirectory(temporary, expectedStem: record.stem)
        try fileManager.moveItem(at: temporary, to: destination)
    }

    func load(stem: String) throws -> MeetingRecord {
        let file = layout.recordDirectory(stem: stem).appendingPathComponent("meeting.json")
        guard fileManager.fileExists(atPath: file.path) else { throw MeetingStoreError.missingRecord }
        do {
            let record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: file))
            guard record.schemaVersion == MeetingRecord.currentSchemaVersion, record.stem == stem else {
                throw MeetingStoreError.corruptRecord
            }
            return record
        } catch let error as MeetingStoreError {
            throw error
        } catch {
            throw MeetingStoreError.corruptRecord
        }
    }

    func list() throws -> [MeetingRecord] {
        try bootstrap()
        let directories = try fileManager.contentsOfDirectory(at: layout.recordings, includingPropertiesForKeys: [.isDirectoryKey])
        return directories.compactMap { directory in
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { return nil }
            return try? load(stem: directory.lastPathComponent)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    func listPeople(records: [MeetingRecord]) throws -> [LocalPersonProfile] {
        try bootstrap()
        var profiles: [String: LocalPersonProfile] = [:]
        let deletedKeys = deletedPeopleKeys()
        let directories = try fileManager.contentsOfDirectory(at: layout.peoples, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        for directory in directories {
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            // peoples/archive preserves absorbed profiles from merges; they
            // are not active people.
            guard directory.lastPathComponent != "archive" else { continue }
            let displayName = directory.lastPathComponent.precomposedStringWithCanonicalMapping
            let key = displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !deletedKeys.contains(key) else { continue }
            let hasVoice = fileManager.fileExists(atPath: directory.appendingPathComponent("voice.npy").path)
            let aliases = profileAliases(in: directory)
            if var existing = profiles[key] {
                existing.hasVoiceProfile = existing.hasVoiceProfile || hasVoice
                for alias in aliases where !existing.aliases.contains(alias) {
                    existing.aliases.append(alias)
                }
                profiles[key] = existing
            } else {
                profiles[key] = LocalPersonProfile(name: displayName, meetingCount: 0, lastMeetingAt: nil, hasVoiceProfile: hasVoice, aliases: aliases)
            }
        }

        // Aliases route confirmations recorded under an absorbed or captured
        // name to the profile that now owns that name, so merged profiles
        // keep their full meeting history without rewriting meeting files.
        var aliasKeys: [String: String] = [:]
        for (key, profile) in profiles {
            for alias in profile.aliases {
                let aliasKey = alias.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if profiles[aliasKey] == nil {
                    aliasKeys[aliasKey] = key
                }
            }
        }

        for record in records {
            // name_only labels the meeting without becoming a person; deleted
            // people stay out even though their past confirmations remain.
            for resolution in record.resolutions where resolution.action != .skip && resolution.action != .nameOnly {
                guard let rawName = resolution.personName?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else { continue }
                let displayName = rawName.precomposedStringWithCanonicalMapping
                let directKey = displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                let key = profiles[directKey] != nil ? directKey : (aliasKeys[directKey] ?? directKey)
                guard !deletedKeys.contains(key), !deletedKeys.contains(directKey) else { continue }
                var profile = profiles[key] ?? LocalPersonProfile(name: displayName, meetingCount: 0, lastMeetingAt: nil, hasVoiceProfile: false)
                profile.meetingCount += 1
                if profile.lastMeetingAt == nil || record.createdAt > profile.lastMeetingAt! {
                    profile.lastMeetingAt = record.createdAt
                }
                profiles[key] = profile
            }
        }
        return profiles.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Reads the human-readable Notes section from a person's canonical
    /// profile.md without touching frontmatter or other sections.
    func profileNotes(name: String) -> String? {
        let slug = Self.profileSlug(name)
        let candidates = [
            layout.peoples.appendingPathComponent(slug, isDirectory: true),
            layout.plaudRoot.appendingPathComponent("me", isDirectory: true),
        ]
        for directory in candidates {
            let profile = directory.appendingPathComponent("profile.md")
            guard let text = try? String(contentsOf: profile, encoding: .utf8) else { continue }
            if directory.lastPathComponent != slug {
                guard let nameLine = text.split(separator: "\n").first(where: { $0.hasPrefix("name: ") }),
                      nameLine.contains("\"\(name)\"") else { continue }
            }
            guard let range = text.range(of: "## Notes") else { continue }
            var notes = String(text[range.upperBound...])
            if let nextSection = notes.range(of: "\n## ") {
                notes = String(notes[..<nextSection.lowerBound])
            }
            let cleaned = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    /// Reads the aliases list from a profile directory's frontmatter. The
    /// line format is python-owned: `aliases: ["A", "B"]` (JSON per line).
    private func profileAliases(in directory: URL) -> [String] {
        let profile = directory.appendingPathComponent("profile.md")
        guard let text = try? String(contentsOf: profile, encoding: .utf8),
              let frontmatterEnd = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: min(3, text.count))..<text.endIndex) else { return [] }
        for line in text[..<frontmatterEnd.lowerBound].split(separator: "\n") where line.hasPrefix("aliases: ") {
            let raw = line.dropFirst("aliases: ".count)
            guard let data = raw.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return parsed.map { $0.precomposedStringWithCanonicalMapping }
        }
        return []
    }

    /// Reads the optional contact email from the profile frontmatter.
    func profileEmail(name: String) -> String? {
        let profile = layout.peoples
            .appendingPathComponent(Self.profileSlug(name), isDirectory: true)
            .appendingPathComponent("profile.md")
        guard let text = try? String(contentsOf: profile, encoding: .utf8),
              let frontmatterEnd = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: min(3, text.count))..<text.endIndex) else { return nil }
        let frontmatter = text[..<frontmatterEnd.lowerBound]
        for line in frontmatter.split(separator: "\n") where line.hasPrefix("email: ") {
            let raw = line.dropFirst("email: ".count).trimmingCharacters(in: .whitespaces)
            let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Matches the Python people.slugify contract for profile directories.
    static func profileSlug(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
        value = value.replacingOccurrences(of: "[/\\\\:*?\"<>|]", with: "_", options: .regularExpression)
        return value.isEmpty ? "unknown" : value
    }

    func update(_ record: MeetingRecord) throws {
        let directory = layout.recordDirectory(stem: record.stem)
        guard fileManager.fileExists(atPath: directory.path) else { throw MeetingStoreError.missingRecord }
        let temporary = layout.staging.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try write(record, to: temporary)
        defer { try? fileManager.removeItem(at: temporary) }
        try validateRecordFile(temporary, expectedStem: record.stem)
        _ = try fileManager.replaceItemAt(directory.appendingPathComponent("meeting.json"), withItemAt: temporary)
    }

    /// Removes only the generated outputs whose meaning depends on the
    /// previous phase-one speaker labels. Raw audio, raw transcript evidence,
    /// corrections, and unrelated meeting metadata are deliberately outside
    /// this fixed allowlist.
    func invalidatePhaseOneDependents(stem: String) throws {
        guard isSafeStem(stem) else { throw MeetingStoreError.invalidStem }
        let directory = layout.recordDirectory(stem: stem)
        guard fileManager.fileExists(atPath: directory.path) else { throw MeetingStoreError.missingRecord }
        let artifactNames = [
            "resolutions.yaml",
            "transcript.json",
            "summary.json",
            "transcript.cleaned.json",
            "speaker_hints.json",
            "transcript.md",
        ]

        for name in artifactNames {
            let artifact = directory.appendingPathComponent(name)
            let values: URLResourceValues
            do {
                // Ask the link itself for its type so dangling links are also
                // removed instead of being mistaken for an absent artifact.
                values = try artifact.resourceValues(forKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
            } catch {
                let cocoaError = error as NSError
                let absentCodes = [
                    CocoaError.Code.fileNoSuchFile.rawValue,
                    CocoaError.Code.fileReadNoSuchFile.rawValue,
                ]
                guard cocoaError.domain == NSCocoaErrorDomain,
                      absentCodes.contains(cocoaError.code) else {
                    throw error
                }
                continue
            }
            guard values.isDirectory != true,
                  values.isRegularFile == true || values.isSymbolicLink == true else {
                throw MeetingStoreError.unsafeArtifactType
            }
            try fileManager.removeItem(at: artifact)
        }
    }

    func checksum(stem: String) throws -> String {
        let directory = layout.recordDirectory(stem: stem)
        guard fileManager.fileExists(atPath: directory.path) else { throw MeetingStoreError.missingRecord }
        let files = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var hasher = SHA256()
        for file in files {
            hasher.update(data: Data(file.lastPathComponent.utf8))
            hasher.update(data: try Data(contentsOf: file))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Permanently removes one meeting's directory, including its audio and
    /// processing artifacts. Callers own the explicit user confirmation.
    func delete(stem: String) throws {
        guard isSafeStem(stem) else { throw MeetingStoreError.invalidStem }
        let directory = layout.recordDirectory(stem: stem)
        guard fileManager.fileExists(atPath: directory.path) else { throw MeetingStoreError.missingRecord }
        try fileManager.removeItem(at: directory)
    }

    func quarantine(stem: String, reason: String) throws {
        try bootstrap()
        let source = layout.recordDirectory(stem: stem)
        guard fileManager.fileExists(atPath: source.path) else { throw MeetingStoreError.missingRecord }
        let target = layout.quarantine.appendingPathComponent("\(stem)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: source, to: target)
        try Data(reason.utf8).write(to: target.appendingPathComponent("reason.txt"), options: .atomic)
    }

    /// Resolves work left in the private staging directory by an interrupted
    /// commit. A validated record is promoted only when its canonical stem is
    /// still absent. Anything ambiguous is preserved in quarantine instead of
    /// overwriting a known-good record or being presented as complete.
    func recoverInterruptedCommits() throws -> [StagedCommitRecovery] {
        try bootstrap()
        let candidates = try fileManager.contentsOfDirectory(at: layout.staging, includingPropertiesForKeys: [.isDirectoryKey])
        var recovered: [StagedCommitRecovery] = []

        for candidate in candidates.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let values = try candidate.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else {
                    try quarantineStaged(candidate, reason: "staging_entry_not_directory")
                    recovered.append(.quarantined(reason: "staging_entry_not_directory"))
                    continue
                }
                let record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: candidate.appendingPathComponent("meeting.json")))
                try validateCommittedDirectory(candidate, expectedStem: record.stem)
                let destination = layout.recordDirectory(stem: record.stem)
                guard !fileManager.fileExists(atPath: destination.path) else {
                    try quarantineStaged(candidate, reason: "canonical_record_already_exists")
                    recovered.append(.quarantined(reason: "canonical_record_already_exists"))
                    continue
                }
                try fileManager.moveItem(at: candidate, to: destination)
                recovered.append(.committed(stem: record.stem))
            } catch {
                try quarantineStaged(candidate, reason: "staging_record_invalid")
                recovered.append(.quarantined(reason: "staging_record_invalid"))
            }
        }
        return recovered
    }

    private func readManifest() throws -> StoreManifest {
        try decoder.decode(StoreManifest.self, from: Data(contentsOf: layout.manifest))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func validateCommittedDirectory(_ directory: URL, expectedStem: String) throws {
        try validateRecordFile(directory.appendingPathComponent("meeting.json"), expectedStem: expectedStem)
    }

    private func validateRecordFile(_ file: URL, expectedStem: String) throws {
        let record = try decoder.decode(MeetingRecord.self, from: Data(contentsOf: file))
        guard record.schemaVersion == MeetingRecord.currentSchemaVersion, record.stem == expectedStem else {
            throw MeetingStoreError.corruptRecord
        }
    }

    private func quarantineStaged(_ candidate: URL, reason: String) throws {
        let target = layout.quarantine.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: target, withIntermediateDirectories: false)
        try fileManager.moveItem(at: candidate, to: target.appendingPathComponent("payload"))
        try Data(reason.utf8).write(to: target.appendingPathComponent("reason.txt"), options: .atomic)
    }

    private func isSafeStem(_ stem: String) -> Bool {
        !stem.isEmpty && !stem.contains("/") && !stem.contains("\\") && stem != "." && stem != ".."
    }

    private func isSafeArtifactName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }
}
