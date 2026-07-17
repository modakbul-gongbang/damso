import Foundation
import Testing
@testable import Damso

/// Regression coverage for removing a person from People: archive-first
/// folder preservation, denylist filtering against synthesis from past
/// meeting resolutions, revival on re-confirmation, and the name_only
/// resolution never becoming a person at all. All tests run against a
/// temporary store and never touch the real one.

@MainActor
private func makeStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    try store.bootstrap()
    return (store, root)
}

private func writeProfile(root: URL, name: String, aliases: [String] = []) throws {
    let directory = root.appendingPathComponent("Plaud/peoples/\(MeetingStore.profileSlug(name))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lines = [
        "name: \"\(name)\"",
        "aliases: \(String(data: try JSONEncoder().encode(aliases), encoding: .utf8)!)",
        "meeting_count: 1",
        "voice_samples: 0",
    ]
    try Data(("---\n" + lines.joined(separator: "\n") + "\n---\n## Notes\n").utf8)
        .write(to: directory.appendingPathComponent("profile.md"))
}

struct ProfileDeleteTests {
    @Test @MainActor
    func deleteArchivesTheFolderAndKeepsThePersonOutDespitePastConfirmations() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProfile(root: root, name: "김잘못", aliases: ["Wrong Kim"])

        var record = try store.createRecord(MeetingDraft(stem: "delete-fixture", source: .local, title: "t"))
        record.resolutions = [SpeakerResolution(speaker: "SPEAKER_00", action: .match, personName: "김잘못", alias: nil)]
        try store.commit(record)

        let outcome = try store.deletePerson(named: "김잘못", aliases: ["Wrong Kim"])
        // Archive-first: the folder is preserved verbatim before disappearing.
        let archiveDirectory = try #require(outcome.archiveDirectory)
        #expect(FileManager.default.fileExists(atPath: archiveDirectory.appendingPathComponent("profile.md").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Plaud/peoples/김잘못").path))

        // Past meeting confirmations no longer resurface the person, under
        // the primary name or an alias.
        let people = try store.listPeople(records: [record])
        #expect(!people.contains { $0.name == "김잘못" })
        var aliased = try store.createRecord(MeetingDraft(stem: "delete-alias-fixture", source: .local, title: "t"))
        aliased.resolutions = [SpeakerResolution(speaker: "SPEAKER_00", action: .match, personName: "Wrong Kim", alias: nil)]
        try store.commit(aliased)
        #expect(!(try store.listPeople(records: [aliased])).contains { $0.name.localizedCaseInsensitiveCompare("Wrong Kim") == .orderedSame })
    }

    @Test @MainActor
    func confirmingTheNameAgainRevivesTheDeletedPerson() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeProfile(root: root, name: "김재확인")
        _ = try store.deletePerson(named: "김재확인", aliases: [])
        #expect(!(try store.listPeople(records: [])).contains { $0.name == "김재확인" })

        // A later match/new confirmation lifts the denylist entry (the
        // backend recreates the profile folder in the same step).
        store.unmarkPersonDeleted("김재확인")
        var record = try store.createRecord(MeetingDraft(stem: "revive-fixture", source: .local, title: "t"))
        record.resolutions = [SpeakerResolution(speaker: "SPEAKER_00", action: .match, personName: "김재확인", alias: nil)]
        try store.commit(record)
        #expect((try store.listPeople(records: [record])).contains { $0.name == "김재확인" })
    }

    @Test @MainActor
    func nameOnlyResolutionsNeverBecomePeople() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try store.createRecord(MeetingDraft(stem: "name-only-fixture", source: .local, title: "t"))
        record.resolutions = [
            SpeakerResolution(speaker: "SPEAKER_00", action: .nameOnly, personName: "일회성게스트", alias: nil),
            SpeakerResolution(speaker: "SPEAKER_01", action: .new, personName: "김프로필", alias: nil),
        ]
        try store.commit(record)

        let people = try store.listPeople(records: [record])
        #expect(!people.contains { $0.name == "일회성게스트" })
        #expect(people.contains { $0.name == "김프로필" })
    }
}
