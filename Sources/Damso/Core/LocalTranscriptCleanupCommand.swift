import Foundation

struct LocalTranscriptCleanupRequest: Encodable, Sendable {
    let operation = "transcript-cleanup"
    let recordingDirectory: String
    let agent: String

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
        case agent
    }

    init(recordingDirectory: String, agent: SummaryAgent) {
        self.recordingDirectory = recordingDirectory
        self.agent = agent.rawValue
    }
}

struct LocalTranscriptCleanupResult: Decodable, Equatable, Sendable {
    let ok: Bool
    let status: String?
    let errorCode: String?
    let correctionCount: Int?

    enum CodingKeys: String, CodingKey {
        case ok
        case status
        case errorCode = "error_code"
        case correctionCount = "correction_count"
    }
}

enum LocalTranscriptCleanupCommandError: Error, Equatable {
    case requestEncoding
    case launchFailed
    case failed
    case invalidResponse
    case oversizedResponse
}

enum LocalTranscriptCleanupProcessRunner {
    static func run(_ request: LocalTranscriptCleanupRequest, client: DamsoHTTPClient = DamsoHTTPClient()) throws -> LocalTranscriptCleanupResult {
        let data: Data
        do {
            data = try client.send(request)
        } catch DamsoServerError.payloadTooLarge {
            throw LocalTranscriptCleanupCommandError.oversizedResponse
        } catch {
            throw LocalTranscriptCleanupCommandError.launchFailed
        }
        guard let result = try? JSONDecoder().decode(LocalTranscriptCleanupResult.self, from: data) else {
            throw LocalTranscriptCleanupCommandError.invalidResponse
        }
        return result
    }
}
