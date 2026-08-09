import Foundation
import Testing
@testable import Damso

private func remoteLauncher(storeRootPath: String = "/Volumes/DamsoMini/Application Support/Damso") -> CommandLauncher {
    let configuration = RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())
    configuration.configureRemote(host: "mini", interpreterPath: "/opt/homebrew/bin/python3.12", storeRootPath: storeRootPath)
    return CommandLauncher(configuration: configuration)
}

private func makeRemoteStore(cacheRoot: URL, outboxRoot: URL, storeRootPath: String = "/Volumes/DamsoMini/Application Support/Damso") -> RemoteMeetingStore {
    RemoteMeetingStore(launcher: remoteLauncher(storeRootPath: storeRootPath), cacheRoot: cacheRoot, outboxRoot: outboxRoot)
}

private func temporaryDirectoryPair() -> (cache: URL, outbox: URL) {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    return (base.appendingPathComponent("cache", isDirectory: true), base.appendingPathComponent("outbox", isDirectory: true))
}

@Test
func remoteMeetingStorePathsResolveAgainstTheMiniRootNotTheLocalCache() throws {
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    let store = makeRemoteStore(cacheRoot: cacheRoot, outboxRoot: outboxRoot)

    #expect(store.storeRootPath == "/Volumes/DamsoMini/Application Support/Damso")
    #expect(store.peoplesDirectoryPath == "/Volumes/DamsoMini/Application Support/Damso/Plaud/peoples")
    #expect(store.recordDirectoryPath(stem: "fixture") == "/Volumes/DamsoMini/Application Support/Damso/Plaud/recordings/fixture")
    // Nothing exists in either root yet, so an unknown stem still resolves to
    // the cache location (the eventual home once synced), not the outbox.
    #expect(store.recordDirectoryURL(stem: "fixture") == cacheRoot.appendingPathComponent("Plaud/recordings/fixture", isDirectory: true))
}

@Test
func remoteMeetingStoreIsNotConfiguredWithoutARemoteStoreRoot() {
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    let unconfigured = RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())
    let store = RemoteMeetingStore(launcher: CommandLauncher(configuration: unconfigured), cacheRoot: cacheRoot, outboxRoot: outboxRoot)

    #expect(store.isConfigured == false)
    #expect(store.health() == .unavailable("Remote execution is not configured. Set it up in Settings."))
}

@Test
func remoteMeetingStoreReadsDelegateToTheLocalCacheNotTheMini() throws {
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    let cache = MeetingStore(root: cacheRoot, minimumFreeBytes: 0)
    let record = try cache.createRecord(MeetingDraft(stem: "cached-fixture", source: .local, title: "Cached"))
    try cache.commit(record)

    let store = makeRemoteStore(cacheRoot: cacheRoot, outboxRoot: outboxRoot)

    let loaded = try store.load(stem: "cached-fixture")
    #expect(loaded.title == "Cached")
    let listed = try store.list()
    #expect(listed.map(\.stem) == ["cached-fixture"])
}

@Test
func creatingAndCommittingARecordWritesToTheOutboxNotTheCache() throws {
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    let store = makeRemoteStore(cacheRoot: cacheRoot, outboxRoot: outboxRoot)

    let record = try store.createRecord(MeetingDraft(stem: "outbox-fixture", source: .local, title: "Fixture"))
    try store.commit(record)

    #expect(FileManager.default.fileExists(atPath: outboxRoot.appendingPathComponent("Plaud/recordings/outbox-fixture/meeting.json").path))
    #expect(!FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("Plaud/recordings/outbox-fixture/meeting.json").path))
    #expect(store.recordDirectoryURL(stem: "outbox-fixture") == outboxRoot.appendingPathComponent("Plaud/recordings/outbox-fixture", isDirectory: true))
    let loaded = try store.load(stem: "outbox-fixture")
    #expect(loaded.title == "Fixture")
    #expect(try store.list().map(\.stem) == ["outbox-fixture"])
}

@Test
func updatingAnOutboxOnlyRecordWritesLocallyWithoutContactingTheMini() throws {
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    // A launcher with no configured remote host: if update() tried to reach
    // damso.serve for an outbox-only record, this would throw instead of
    // silently succeeding, so a passing test proves the local branch ran.
    let store = RemoteMeetingStore(launcher: CommandLauncher(configuration: RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())), cacheRoot: cacheRoot, outboxRoot: outboxRoot)
    var record = try store.createRecord(MeetingDraft(stem: "outbox-update-fixture", source: .local, title: "Before"))
    try store.commit(record)

    record.title = "After"
    try store.update(record)

    #expect(try store.load(stem: "outbox-update-fixture").title == "After")
}

@Test
func updatingAnAlreadyHandedOffRecordNeverWritesTheCacheDirectlyAndThrowsInstead() throws {
    // A synced (already handed-off) record has no outbox copy: R3's contract
    // is that the macbook never mutates the canonical store directly, so
    // update() must go through damso.serve, not fall back to a local cache
    // write. With no remote host configured, that attempt throws instead of
    // silently succeeding - a passing test proves the remote branch ran and
    // the cache file it would have needed to skip stayed untouched.
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    let cache = MeetingStore(root: cacheRoot, minimumFreeBytes: 0)
    var record = try cache.createRecord(MeetingDraft(stem: "synced-fixture", source: .local, title: "Before"))
    try cache.commit(record)

    let store = RemoteMeetingStore(launcher: CommandLauncher(configuration: RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())), cacheRoot: cacheRoot, outboxRoot: outboxRoot)
    record.title = "After"

    #expect(throws: DamsoServeError.remoteMisconfigured) {
        try store.update(record)
    }
    #expect(try cache.load(stem: "synced-fixture").title == "Before")
}

@Test
func listMergesOutboxOnlyRecordsWithCachedOnesNewestFirstWithoutDuplicates() throws {
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    let cache = MeetingStore(root: cacheRoot, minimumFreeBytes: 0)
    var handedOff = try cache.createRecord(MeetingDraft(stem: "already-handed-off", source: .local, title: "Handed off"))
    handedOff.createdAt = Date(timeIntervalSince1970: 1_000)
    try cache.commit(handedOff)
    // A stale outbox leftover for the same stem (e.g. after a successful
    // handoff that has not been cleaned up yet) must not produce a duplicate.
    let outbox = MeetingStore(root: outboxRoot, minimumFreeBytes: 0)
    try outbox.commit(handedOff)
    var recording = try outbox.createRecord(MeetingDraft(stem: "still-recording", source: .local, title: "In progress"))
    recording.createdAt = Date(timeIntervalSince1970: 2_000)
    try outbox.commit(recording)

    let store = makeRemoteStore(cacheRoot: cacheRoot, outboxRoot: outboxRoot)

    let listed = try store.list()
    #expect(listed.map(\.stem) == ["still-recording", "already-handed-off"])
    // R9(d)'s "전송 대기 N건": only "still-recording" has no cache copy yet -
    // "already-handed-off" is outbox debris left behind after a real handoff
    // and must not inflate the pending count.
    #expect(store.outboxPendingCount() == 1)
}

@Test
func outboxPendingCountIsZeroWithNoOutboxRecordsAtAll() throws {
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    let store = makeRemoteStore(cacheRoot: cacheRoot, outboxRoot: outboxRoot)

    #expect(store.outboxPendingCount() == 0)
}

@Test
func creatingCommittingOrImportingDoesNotThrowAnymoreOnceTheOutboxExists() throws {
    // Regression guard for the T5 placeholder this superseded: these three
    // used to throw RemoteMeetingStoreError.pendingOutboxHandoff
    // unconditionally.
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    let store = makeRemoteStore(cacheRoot: cacheRoot, outboxRoot: outboxRoot)

    let record = try store.createRecord(MeetingDraft(stem: "no-longer-throws", source: .local, title: "Fixture"))
    try store.commit(record)

    #expect(try store.load(stem: "no-longer-throws").stem == "no-longer-throws")
}

@Test
func handOffPushesTheOutboxRecordAndPromotesItOnTheMini() async throws {
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    let miniStoreRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: miniStoreRoot) }
    // A loopback SSH alias would need real network setup unavailable in a
    // unit test; this proves handOff() is a true no-op (no throw, false
    // return) when there is nothing in the outbox to send - the common case
    // on every sweep pass once a record has already been handed off.
    let store = makeRemoteStore(cacheRoot: cacheRoot, outboxRoot: outboxRoot, storeRootPath: miniStoreRoot.path)

    let handedOff = try await store.handOff(stem: "nothing-pending")

    #expect(handedOff == false)
}

@Test
func deleteOutboxAudioIfPhaseOneCompleteDoesNothingUntilTheCacheConfirmsIt() throws {
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    let outbox = MeetingStore(root: outboxRoot, minimumFreeBytes: 0)
    var record = try outbox.createRecord(MeetingDraft(stem: "audio-retention-fixture", source: .local, title: "Fixture"))
    record.originalAudioFile = "microphone.caf"
    try outbox.commit(record)
    let audioURL = outbox.recordDirectoryURL(stem: "audio-retention-fixture").appendingPathComponent("microphone.caf")
    try Data("synthetic audio".utf8).write(to: audioURL)

    let store = makeRemoteStore(cacheRoot: cacheRoot, outboxRoot: outboxRoot)

    // The cache has no transcript.raw.json for this stem yet (T8 has not
    // synced it down), so deletion must not happen.
    #expect(store.deleteOutboxAudioIfPhaseOneComplete(stem: "audio-retention-fixture") == false)
    #expect(FileManager.default.fileExists(atPath: audioURL.path))
}

@Test
func deleteOutboxAudioIfPhaseOneCompleteRemovesOnlyAudioFilesOnceConfirmed() throws {
    let (cacheRoot, outboxRoot) = temporaryDirectoryPair()
    defer { try? FileManager.default.removeItem(at: cacheRoot.deletingLastPathComponent()) }
    let outbox = MeetingStore(root: outboxRoot, minimumFreeBytes: 0)
    var record = try outbox.createRecord(MeetingDraft(stem: "audio-deletion-fixture", source: .local, title: "Fixture"))
    record.originalAudioFile = "microphone.caf"
    record.systemAudioFile = "system-audio.m4a"
    try outbox.commit(record)
    let recordDirectory = outbox.recordDirectoryURL(stem: "audio-deletion-fixture")
    try Data("mic".utf8).write(to: recordDirectory.appendingPathComponent("microphone.caf"))
    try Data("system".utf8).write(to: recordDirectory.appendingPathComponent("system-audio.m4a"))

    let cache = MeetingStore(root: cacheRoot, minimumFreeBytes: 0)
    let cachedRecord = try cache.createRecord(MeetingDraft(stem: "audio-deletion-fixture", source: .local, title: "Fixture"))
    try cache.commit(cachedRecord, artifacts: ["transcript.raw.json": Data("{\"segments\":[]}".utf8)])

    let store = makeRemoteStore(cacheRoot: cacheRoot, outboxRoot: outboxRoot)

    #expect(store.deleteOutboxAudioIfPhaseOneComplete(stem: "audio-deletion-fixture") == true)
    #expect(!FileManager.default.fileExists(atPath: recordDirectory.appendingPathComponent("microphone.caf").path))
    #expect(!FileManager.default.fileExists(atPath: recordDirectory.appendingPathComponent("system-audio.m4a").path))
    // meeting.json itself is untouched - only the audio is R6's contract.
    #expect(FileManager.default.fileExists(atPath: recordDirectory.appendingPathComponent("meeting.json").path))
}

@Test
func updateRecordRequestEncodesTheFullRecordWithCanonicalDateFormattingAndFieldNames() throws {
    let record = MeetingRecord(stem: "fixture", source: .local, title: "Renamed", hints: MeetingHints(participants: [], topic: nil, domainTerms: [], numSpeakers: nil))
    let request = UpdateRecordRequest(recordingDirectory: "/mini/Plaud/recordings/fixture", record: record)

    let encoder = JSONEncoder()
    DateCoding.configure(encoder)
    let fields = try #require(try JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])

    #expect(fields["operation"] as? String == "update-record")
    #expect(fields["recording_directory"] as? String == "/mini/Plaud/recordings/fixture")
    let encodedRecord = try #require(fields["record"] as? [String: Any])
    #expect(encodedRecord["stem"] as? String == "fixture")
    #expect(encodedRecord["title"] as? String == "Renamed")
    let createdAt = try #require(encodedRecord["createdAt"] as? String)
    #expect(createdAt.hasSuffix("Z"))
    #expect(createdAt.contains("T"))
}

@Test
func deleteRecordAndQuarantineRecordRequestsCarryOnlyTheirRequiredFields() throws {
    let deleteFields = try encodedFields(DeleteRecordRequest(recordingDirectory: "/mini/Plaud/recordings/fixture"))
    #expect(deleteFields["operation"] as? String == "delete-record")
    #expect(deleteFields["recording_directory"] as? String == "/mini/Plaud/recordings/fixture")

    let quarantineFields = try encodedFields(QuarantineRecordRequest(recordingDirectory: "/mini/Plaud/recordings/fixture", reason: "recording_start_failed"))
    #expect(quarantineFields["operation"] as? String == "quarantine-record")
    #expect(quarantineFields["reason"] as? String == "recording_start_failed")
}

@Test
func commitRecordRequestUsesSnakeCaseFieldNames() throws {
    let fields = try encodedFields(CommitRecordRequest(stagingDirectory: "/mini/.staging/abc", recordingDirectory: "/mini/Plaud/recordings/fixture"))
    #expect(fields["operation"] as? String == "commit-record")
    #expect(fields["staging_directory"] as? String == "/mini/.staging/abc")
    #expect(fields["recording_directory"] as? String == "/mini/Plaud/recordings/fixture")
}

@Test
func mergeProfilesAndDeletePersonRequestsUseSnakeCaseFieldNames() throws {
    let mergeFields = try encodedFields(MergeProfilesRequest(peoplesDirectory: "/mini/Plaud/peoples", primaryName: "Kim", absorbedName: "Kim2"))
    #expect(mergeFields["operation"] as? String == "merge-profiles")
    #expect(mergeFields["peoples_directory"] as? String == "/mini/Plaud/peoples")
    #expect(mergeFields["primary_name"] as? String == "Kim")
    #expect(mergeFields["absorbed_name"] as? String == "Kim2")

    let deleteFields = try encodedFields(DeletePersonRequest(peoplesDirectory: "/mini/Plaud/peoples", name: "Kim", aliases: ["김철수"]))
    #expect(deleteFields["operation"] as? String == "delete-person")
    #expect(deleteFields["aliases"] as? [String] == ["김철수"])
}

private func encodedFields(_ request: some Encodable) throws -> [String: Any] {
    let encoder = JSONEncoder()
    DateCoding.configure(encoder)
    return try #require(try JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
}
