import Foundation
import Testing
@testable import Damso

/// Regression for the legacy identification.json format: older imported
/// records store proposals with only `candidates` (plus a `hints` field the
/// app ignores) and no total_seconds/segment_count/excerpts. The reader must
/// still surface the transcript and the proposals instead of throwing and
/// hiding the whole meeting.
struct LegacyArtifactDecodingTests {
    private func makeRecord(identification: String) throws -> (MeetingStore, String) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("damso-legacy-\(UUID().uuidString)")
        let store = MeetingStore(root: root, minimumFreeBytes: 0)
        let stem = "legacy-rec"
        let dir = CanonicalStoreLayout(root: root).recordDirectory(stem: stem)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = """
        {"source_file":"a.ogg","language":"ko","model":"large-v3","duration":20.0,
         "speakers":["SPEAKER_00","SPEAKER_01"],
         "segments":[{"speaker":"SPEAKER_00","start":0.0,"end":8.0,"text":"안녕하세요"},
                     {"speaker":"SPEAKER_01","start":8.0,"end":18.0,"text":"네 반갑습니다"}]}
        """
        try raw.write(to: dir.appendingPathComponent("transcript.raw.json"), atomically: true, encoding: .utf8)
        try identification.write(to: dir.appendingPathComponent("identification.json"), atomically: true, encoding: .utf8)
        return (store, stem)
    }

    @Test
    func legacyIdentificationStillYieldsTranscriptAndProposals() throws {
        // Only `candidates` + `hints`; no totals or excerpts.
        let legacy = """
        {"version":1,"proposals":{
          "SPEAKER_00":{"candidates":[{"name":"나","voice_score":0.98}],"hints":{}},
          "SPEAKER_01":{"candidates":[{"name":"박바람","voice_score":0.55}],"hints":{}}}}
        """
        let (store, stem) = try makeRecord(identification: legacy)
        let artifacts = try store.processingArtifacts(stem: stem)

        #expect(artifacts.transcript.count == 2)
        #expect(artifacts.proposals.count == 2)
        // Totals are derived from the transcript when the artifact omits them.
        let s0 = try #require(artifacts.proposals.first { $0.speaker == "SPEAKER_00" })
        #expect(s0.totalSeconds == 8.0)
        #expect(s0.segmentCount == 1)
        #expect(s0.candidates.first?.name == "나")
    }

    @Test
    func malformedIdentificationKeepsTranscript() throws {
        let (store, stem) = try makeRecord(identification: "{ not json")
        let artifacts = try store.processingArtifacts(stem: stem)
        // A broken identification.json must not hide the transcript.
        #expect(artifacts.transcript.count == 2)
        #expect(artifacts.proposals.isEmpty)
    }
}
