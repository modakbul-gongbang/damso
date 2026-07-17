import Foundation

enum ProfileDeleteError: Error, Equatable {
    case invalidSelection
    case archiveFailed
}

/// What one deletion did, for the UI confirmation and recovery guidance.
struct ProfileDeleteOutcome: Equatable, Sendable {
    var name: String
    /// Where the profile folder was preserved, when one existed.
    var archiveDirectory: URL?
}

extension MeetingStore {
    /// Removes a person from People without rewriting any meeting. The
    /// profile folder (voice embedding, notes) is archived first under
    /// peoples/archive, then the name and its aliases go on a local denylist
    /// so the People list stops synthesizing the person from past meeting
    /// resolutions. Meetings keep showing the name inline; confirming the
    /// same name again later lifts the denylist entry.
    func deletePerson(named name: String, aliases: [String]) throws -> ProfileDeleteOutcome {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ProfileDeleteError.invalidSelection }
        let layout = CanonicalStoreLayout(root: rootURL)
        let directory = layout.peoples.appendingPathComponent(Self.profileSlug(cleaned), isDirectory: true)

        var archiveDestination: URL?
        if FileManager.default.fileExists(atPath: directory.path) {
            let archiveRoot = layout.peoples.appendingPathComponent("archive", isDirectory: true)
            var destination = archiveRoot.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
                destination = archiveRoot.appendingPathComponent("\(directory.lastPathComponent)-\(stamp)", isDirectory: true)
            }
            do {
                try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: directory, to: destination)
            } catch {
                throw ProfileDeleteError.archiveFailed
            }
            archiveDestination = destination
        }

        markPeopleDeleted([cleaned] + aliases)
        return ProfileDeleteOutcome(name: cleaned, archiveDirectory: archiveDestination)
    }

    private var deletedPeopleURL: URL {
        CanonicalStoreLayout(root: rootURL).peoples.appendingPathComponent(".deleted-people.json")
    }

    /// Folded identity keys of deleted people; names confirmed as one of
    /// these stop appearing in the People list.
    func deletedPeopleKeys() -> Set<String> {
        guard let data = try? Data(contentsOf: deletedPeopleURL),
              let names = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(names.map(LocalPersonProfile.foldingKey))
    }

    func markPeopleDeleted(_ names: [String]) {
        var stored: [String] = (try? Data(contentsOf: deletedPeopleURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        var keys = Set(stored.map(LocalPersonProfile.foldingKey))
        for name in names {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty, keys.insert(LocalPersonProfile.foldingKey(cleaned)).inserted else { continue }
            stored.append(cleaned)
        }
        writeDeletedPeople(stored)
    }

    /// Confirming a person again (match/new/me) revives them.
    func unmarkPersonDeleted(_ name: String) {
        guard let data = try? Data(contentsOf: deletedPeopleURL),
              let stored = try? JSONDecoder().decode([String].self, from: data) else { return }
        let key = LocalPersonProfile.foldingKey(name.trimmingCharacters(in: .whitespacesAndNewlines))
        let remaining = stored.filter { LocalPersonProfile.foldingKey($0) != key }
        guard remaining.count != stored.count else { return }
        writeDeletedPeople(remaining)
    }

    private func writeDeletedPeople(_ names: [String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(names) else { return }
        try? FileManager.default.createDirectory(at: CanonicalStoreLayout(root: rootURL).peoples, withIntermediateDirectories: true)
        try? data.write(to: deletedPeopleURL, options: .atomic)
    }
}
