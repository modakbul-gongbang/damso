import Foundation
import Testing
@testable import Damso

/// Regression coverage for participant capture (R5): participants.json
/// schema and creation, late-joiner polling merge, active-speaker sample
/// accumulation, chromux output parsing, and attach-failure degrade that
/// keeps partial data valid. All fixtures use synthetic names.

private let start = Date(timeIntervalSince1970: 3_000_000)

private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

struct ParticipantCaptureRecorderTests {
    @Test
    func pollingMergesLateJoinersAndAdvancesLastSeen() throws {
        var recorder = ParticipantCaptureRecorder(source: "chrome-meet")
        recorder.observe(names: ["김가상", "박테스트"], at: at(0))
        recorder.observe(names: ["김가상", "박테스트", "이늦참"], at: at(30))
        recorder.observe(names: ["김가상", "이늦참"], at: at(60))

        let participants = recorder.file.participants
        #expect(participants.map(\.name) == ["김가상", "박테스트", "이늦참"])
        #expect(participants[0].firstSeenAt == at(0))
        #expect(participants[0].lastSeenAt == at(60))
        // A participant who left keeps their history; nothing is removed.
        #expect(participants[1].lastSeenAt == at(30))
        #expect(participants[2].firstSeenAt == at(30))
        #expect(participants.allSatisfy { $0.source == "chrome-meet" })
    }

    @Test
    func activeSpeakerSamplesAccumulateAsRecordingOffsets() {
        var recorder = ParticipantCaptureRecorder(source: "chrome-meet")
        recorder.observe(names: ["김가상"], at: at(0))
        recorder.observeActiveSpeakers(["김가상"], atOffset: 12.5, at: at(12.5))
        recorder.observeActiveSpeakers(["김가상"], atOffset: 14.0, at: at(14))
        // A speaker never seen in the participant poll is added by sampling.
        recorder.observeActiveSpeakers(["박발화"], atOffset: 20.0, at: at(20))

        let byName = Dictionary(uniqueKeysWithValues: recorder.file.participants.map { ($0.name, $0) })
        #expect(byName["김가상"]?.speakingSamples == [12.5, 14.0])
        #expect(byName["박발화"]?.speakingSamples == [20.0])
        // Participants who never spoke omit the field entirely.
        var quiet = ParticipantCaptureRecorder(source: "chrome-meet")
        quiet.observe(names: ["조용한사람"], at: at(0))
        #expect(quiet.file.participants.first?.speakingSamples == nil)
    }

    @Test
    func encodedFileMatchesTheContractSchema() throws {
        var recorder = ParticipantCaptureRecorder(source: "chrome-meet")
        recorder.observe(names: ["김가상"], at: at(0))
        recorder.observeActiveSpeakers(["김가상"], atOffset: 3.0, at: at(3))
        let data = try recorder.encoded()

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let participants = try #require(object["participants"] as? [[String: Any]])
        let entry = try #require(participants.first)
        #expect(entry["name"] as? String == "김가상")
        #expect(entry["source"] as? String == "chrome-meet")
        #expect(entry["firstSeenAt"] is String)
        #expect(entry["lastSeenAt"] is String)
        #expect(entry["speakingSamples"] as? [Double] == [3.0])

        // Round-trips through the reader used by the pipeline.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("participants-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let read = try #require(MeetingParticipantsFile.read(from: url))
        #expect(read.participants.count == 1)
        #expect(read.participants.first?.firstSeenAt == at(0))
    }
}

struct ParticipantCaptureScriptOutputTests {
    @Test
    func parsesCleanAndWrappedChromuxOutput() {
        let clean = Data(#"{"kind":"participants","participants":["김가상","박테스트"]}"#.utf8)
        #expect(MeetingDOMScriptOutput.participantNames(from: clean) == ["김가상", "박테스트"])

        let wrapped = Data(#"""
        run ok (1 step)
        {"result":{"value":"{\"kind\":\"participants\",\"participants\":[\"김가상\"]}"},"elapsedMs":120}
        """#.utf8)
        #expect(MeetingDOMScriptOutput.participantNames(from: wrapped) == ["김가상"])

        let speakers = Data(#"{"kind":"activeSpeakers","activeSpeakers":["박발화"]}"#.utf8)
        #expect(MeetingDOMScriptOutput.activeSpeakerNames(from: speakers) == ["박발화"])

        #expect(MeetingDOMScriptOutput.participantNames(from: Data("no json here".utf8)) == nil)
        #expect(MeetingDOMScriptOutput.participantNames(from: Data(#"{"other":1}"#.utf8)) == nil)
    }

    @Test
    func dropsGoogleIconGlyphNamesLeakedIntoScrapedText() {
        // Live Meet call (2026-07-17): icon-font glyph names arrived as
        // participants alongside real names. Real lowercase handles stay.
        let leaked = Data(#"{"kind":"participants","participants":["gggg","frame_person","devices","호연 테스트"]}"#.utf8)
        #expect(MeetingDOMScriptOutput.participantNames(from: leaked) == ["gggg", "호연 테스트"])

        let speakers = Data(#"{"kind":"activeSpeakers","activeSpeakers":["mic_off","박발화"]}"#.utf8)
        #expect(MeetingDOMScriptOutput.activeSpeakerNames(from: speakers) == ["박발화"])

        #expect(MeetingDOMScriptOutput.isLikelyIconGlyphName("visual_effects"))
        #expect(MeetingDOMScriptOutput.isLikelyIconGlyphName("devices"))
        #expect(!MeetingDOMScriptOutput.isLikelyIconGlyphName("Devices Kim"))
        #expect(!MeetingDOMScriptOutput.isLikelyIconGlyphName("gggg"))
        #expect(!MeetingDOMScriptOutput.isLikelyIconGlyphName("Hoyeon Lee"))
        #expect(!MeetingDOMScriptOutput.isLikelyIconGlyphName("이_호연")) // non-ascii with underscore is not a glyph
    }
}

// MARK: - Capture loop behavior with a synthetic provider

private actor ScriptedProvider: ParticipantSnapshotProviding {
    var attachResults: [Bool]
    var participantResults: [[String]?]
    var attachCalls = 0

    init(attachResults: [Bool], participantResults: [[String]?]) {
        self.attachResults = attachResults
        self.participantResults = participantResults
    }

    func attach() async -> Bool {
        attachCalls += 1
        return attachResults.isEmpty ? false : attachResults.removeFirst()
    }

    func participantNames() async -> [String]? {
        participantResults.isEmpty ? nil : participantResults.removeFirst()
    }

    func activeSpeakerNames() async -> [String]? { nil }

    func detach() async {}

    func attachAttempts() -> Int { attachCalls }
}

struct ParticipantCaptureControllerTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test @MainActor
    func attachFailureDegradesWithoutBlockingAndRetries() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ScriptedProvider(attachResults: [false, false, true], participantResults: [["김가상"]])
        let controller = MeetingParticipantCaptureController(
            provider: provider,
            recordingDirectory: directory,
            recordingStartedAt: Date(),
            source: "chrome-meet",
            pollInterval: 0.05,
            sampleInterval: 10,
            attachRetryInterval: 0.05
        )
        var statuses: [(Int?, Bool)] = []
        controller.onStatus = { statuses.append(($0, $1)) }
        controller.start()

        // Two failed attaches, then success and a first poll.
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("participants.json").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.stop()

        #expect(await provider.attachAttempts() == 3)
        #expect(statuses.contains { $0.1 == false })
        #expect(statuses.contains { $0.0 == 1 && $0.1 == true })
        let file = try #require(MeetingParticipantsFile.read(from: directory.appendingPathComponent("participants.json")))
        #expect(file.participants.map(\.name) == ["김가상"])
    }

    @Test @MainActor
    func lostTabKeepsPartialCaptureAndNeverWritesEmptyFiles() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Attach succeeds, one good poll, then the script starts failing.
        let provider = ScriptedProvider(attachResults: [true, false, false, false, false], participantResults: [["김가상", "박테스트"], nil])
        let controller = MeetingParticipantCaptureController(
            provider: provider,
            recordingDirectory: directory,
            recordingStartedAt: Date(),
            source: "chrome-meet",
            pollInterval: 0.03,
            sampleInterval: 10,
            attachRetryInterval: 0.03
        )
        controller.start()
        for _ in 0..<200 {
            if await provider.attachAttempts() >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.stop()

        // The partial capture from the good poll survives the failure.
        let file = try #require(MeetingParticipantsFile.read(from: directory.appendingPathComponent("participants.json")))
        #expect(file.participants.map(\.name) == ["김가상", "박테스트"])
    }

    @Test @MainActor
    func noCaptureMeansNoParticipantsFileAndPipelineStaysValid() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = ScriptedProvider(attachResults: [false], participantResults: [])
        let controller = MeetingParticipantCaptureController(
            provider: provider,
            recordingDirectory: directory,
            recordingStartedAt: Date(),
            source: "chrome-meet",
            pollInterval: 0.03,
            sampleInterval: 10,
            attachRetryInterval: 5
        )
        controller.start()
        try await Task.sleep(for: .milliseconds(80))
        controller.stop()

        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("participants.json").path))
        // The artifact reader treats a missing file as a valid empty state.
        #expect(MeetingParticipantsFile.read(from: directory.appendingPathComponent("participants.json")) == nil)
    }
}
