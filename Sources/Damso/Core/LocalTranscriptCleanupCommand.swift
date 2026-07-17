import Foundation

struct LocalTranscriptCleanupCommand: Equatable, Sendable {
    let pythonExecutable: String

    init(pythonExecutable: String = "python3") {
        self.pythonExecutable = pythonExecutable
    }

    var arguments: [String] {
        [pythonExecutable, "-m", "damso.transcript_cleanup", "--request", "-"]
    }
}

struct LocalTranscriptCleanupRequest: Encodable, Sendable {
    let recordingDirectory: String
    let agent: String

    enum CodingKeys: String, CodingKey {
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
    private static let maximumResponseBytes = 64 * 1_024

    static func run(_ request: LocalTranscriptCleanupRequest, command: LocalTranscriptCleanupCommand = .init()) throws -> LocalTranscriptCleanupResult {
        let input: Data
        do {
            input = try JSONEncoder().encode(request)
        } catch {
            throw LocalTranscriptCleanupCommandError.requestEncoding
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command.arguments
        process.environment = ProcessRuntime.environment()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw LocalTranscriptCleanupCommandError.launchFailed
        }
        standardInput.fileHandleForWriting.write(input)
        try? standardInput.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard output.count <= maximumResponseBytes else {
            throw LocalTranscriptCleanupCommandError.oversizedResponse
        }
        guard process.terminationStatus == 0 else {
            throw LocalTranscriptCleanupCommandError.failed
        }
        guard let result = try? JSONDecoder().decode(LocalTranscriptCleanupResult.self, from: output) else {
            throw LocalTranscriptCleanupCommandError.invalidResponse
        }
        return result
    }
}
