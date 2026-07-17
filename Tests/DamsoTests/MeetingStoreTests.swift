import Foundation
import Testing
@testable import Damso

@Test
func commitsOnlyValidatedRecordsAndPreservesChecksums() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    let record = try store.createRecord(MeetingDraft(stem: "fixture-one", source: .local, title: "Synthetic fixture"))

    try store.commit(record, artifacts: ["hint.json": Data("{}".utf8)])

    let loaded = try store.load(stem: "fixture-one")
    #expect(loaded == record)
    #expect(try store.list() == [record])
    #expect(try store.checksum(stem: "fixture-one").count == 64)
    #expect(throws: MeetingStoreError.self) {
        try store.commit(record)
    }
}

@Test
func deleteRemovesTheMeetingDirectoryAndRejectsUnsafeOrMissingStems() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    let record = try store.createRecord(MeetingDraft(stem: "deletable-fixture", source: .local, title: "Synthetic fixture"))
    try store.commit(record, artifacts: ["audio.caf": Data("audio".utf8)])

    try store.delete(stem: "deletable-fixture")

    #expect(try store.list().isEmpty)
    #expect(throws: MeetingStoreError.missingRecord) {
        try store.load(stem: "deletable-fixture")
    }
    #expect(throws: MeetingStoreError.missingRecord) {
        try store.delete(stem: "deletable-fixture")
    }
    #expect(throws: MeetingStoreError.invalidStem) {
        try store.delete(stem: "../unsafe")
    }
}

@Test
func blocksPathTraversalAndRedactsSensitiveLedgerText() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    #expect(throws: MeetingStoreError.self) {
        try store.createRecord(MeetingDraft(stem: "../unsafe", source: .plaud, title: "Synthetic fixture"))
    }

    let ledger = OperationLedger(fileURL: root.appendingPathComponent("ledger.json"), maximumEntries: 2)
    try ledger.append(OperationEvent(timestamp: .now, level: .error, code: "fixture", meetingStem: nil, message: "Authorization: Bearer secret-value cookie=session-value key=sk-test-token path=\(NSHomeDirectory()) file:///private/tmp/meeting.json", nextAction: "Open /Volumes/External/Damso"))
    let message = try #require(ledger.read().first?.message)
    #expect(!message.contains("secret-value"))
    #expect(!message.contains("session-value"))
    #expect(!message.contains("sk-test-token"))
    #expect(!message.contains(NSHomeDirectory()))
    #expect(message.lowercased().contains("authorization=<redacted>"))
    #expect(message.contains("<file-url>"))
    #expect(!message.contains("/private/tmp/meeting.json"))
    #expect(!message.contains("/Volumes/External/Damso"))
}

@Test
func interruptedStagingCommitIsPromotedOnlyWhenTheRecordIsValidatedAndUnique() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    try store.bootstrap()
    let record = MeetingRecord(stem: "recovered-fixture", source: .local, title: "Synthetic recovery")
    let staging = root.appendingPathComponent(".staging/recoverable", isDirectory: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    DateCoding.configure(encoder)
    try encoder.encode(record).write(to: staging.appendingPathComponent("meeting.json"))

    #expect(try store.recoverInterruptedCommits() == [.committed(stem: "recovered-fixture")])
    #expect(try store.load(stem: "recovered-fixture") == record)

    let malformed = root.appendingPathComponent(".staging/malformed", isDirectory: true)
    try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
    try Data("not-a-record".utf8).write(to: malformed.appendingPathComponent("meeting.json"))
    #expect(try store.recoverInterruptedCommits() == [.quarantined(reason: "staging_record_invalid")])
    let quarantine = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".quarantine"), includingPropertiesForKeys: nil)
    #expect(quarantine.count == 1)
}

@Test
func correctionsAndRetriesPreserveOriginalResultsAndDiagnosticsExportRemovesMeetingIdentity() throws {
    let originalTranscript = [TranscriptSegment(speaker: "Speaker A", startSeconds: 0, endSeconds: 4, text: "Original local text")]
    let originalSummary = StructuredSummary(oneLine: "Original", keyDiscussion: ["Original point"], actionItems: [], roleHints: [:], topicSummary: "Original topic")
    let record = MeetingRecord(stem: "sensitive-fixture", source: .local, title: "Original title", stage: .failed, transcript: originalTranscript, summary: originalSummary)
    let correctedTranscript = [TranscriptSegment(speaker: "Kim", startSeconds: 0, endSeconds: 4, text: "Corrected text")]
    let corrections = MeetingCorrections(title: "Corrected title", transcript: correctedTranscript, summary: nil)
    let updated = MeetingDetailActions.applying(corrections, to: record)

    #expect(updated.transcript == originalTranscript)
    #expect(updated.summary == originalSummary)
    #expect(updated.corrections == corrections)
    #expect(MeetingDetailActions.retry(.summarizing, for: updated).stage == .summarizing)
    #expect(MeetingDetailActions.reprocessAll(for: updated).stage == .queued)

    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = OperationLedger(fileURL: root.appendingPathComponent("ledger.json"))
    try ledger.append(OperationEvent(timestamp: .now, level: .error, code: "fixture_failure", meetingStem: "sensitive-fixture", message: "token=secret-value transcript=Original local text", nextAction: "Open /private/tmp/audio.caf"))
    let exported = try ledger.exportRedacted()
    #expect(!exported.contains("sensitive-fixture"))
    #expect(!exported.contains("secret-value"))
    #expect(!exported.contains("/private/tmp/audio.caf"))
}

@Test
func speakerHintsCacheRoundTripsAndGroupsBySpeaker() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(root: root, minimumFreeBytes: 0)
    let record = try store.createRecord(MeetingDraft(stem: "hints-fixture", source: .local, title: "Synthetic fixture"))
    try store.commit(record, artifacts: ["hint.json": Data("{}".utf8)])

    #expect(!store.hasCachedSpeakerSuggestions(stem: "hints-fixture"))

    let suggestions = [
        SpeakerSuggestion(speaker: "SPEAKER_00", name: "김구름", confidence: 0.8, reason: "커리큘럼 초안을 설명함"),
        SpeakerSuggestion(speaker: "SPEAKER_00", name: "이노을", confidence: 0.3, reason: "일정 언급"),
        SpeakerSuggestion(speaker: "SPEAKER_01", name: "이재규", confidence: 0.6, reason: "가격 논의 주도"),
    ]
    store.writeSpeakerSuggestions(suggestions, stem: "hints-fixture")

    #expect(store.hasCachedSpeakerSuggestions(stem: "hints-fixture"))
    let cached = store.cachedSpeakerSuggestions(stem: "hints-fixture")
    #expect(cached["SPEAKER_00"]?.count == 2)
    #expect(cached["SPEAKER_01"]?.first?.reason == "가격 논의 주도")
}
