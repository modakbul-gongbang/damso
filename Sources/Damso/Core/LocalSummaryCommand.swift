import Foundation

struct LocalSummaryCommand: Equatable, Sendable {
    let pythonExecutable: String

    init(pythonExecutable: String = "python3") {
        self.pythonExecutable = pythonExecutable
    }

    var arguments: [String] {
        [pythonExecutable, "-m", "damso.summary", "--request", "-"]
    }
}

enum SummaryAgent: String, Codable, CaseIterable, Sendable {
    case claude
    case codex

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    var executableName: String { rawValue }
}

enum SummaryLanguage: String, Codable, CaseIterable, Sendable {
    case korean = "ko"
    case english = "en"
}

struct LocalSummaryRequest: Encodable, Sendable {
    let recordingDirectory: String
    let agent: String
    let language: String

    enum CodingKeys: String, CodingKey {
        case recordingDirectory = "recording_directory"
        case agent
        case language
    }

    init(recordingDirectory: String, agent: SummaryAgent, language: SummaryLanguage) {
        self.recordingDirectory = recordingDirectory
        self.agent = agent.rawValue
        self.language = language.rawValue
    }
}

struct LocalSummaryResult: Decodable, Equatable, Sendable {
    let ok: Bool
    let status: String?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case status
        case errorCode = "error_code"
    }
}

enum LocalSummaryCommandError: Error, Equatable {
    case requestEncoding
    case launchFailed
    case failed
    case invalidResponse
    case oversizedResponse
}

/// Starts the fixed local Python module with JSON stdin only. The request has
/// no transcript text, CLI argument, or secret. The Python boundary reads the
/// canonical local artifact and returns only a bounded status object.
enum LocalSummaryProcessRunner {
    private static let maximumResponseBytes = 64 * 1_024

    static func run(_ request: LocalSummaryRequest, command: LocalSummaryCommand = .init()) throws -> LocalSummaryResult {
        let input: Data
        do {
            input = try JSONEncoder().encode(request)
        } catch {
            throw LocalSummaryCommandError.requestEncoding
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
            throw LocalSummaryCommandError.launchFailed
        }
        standardInput.fileHandleForWriting.write(input)
        try? standardInput.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard output.count <= maximumResponseBytes else {
            throw LocalSummaryCommandError.oversizedResponse
        }
        guard process.terminationStatus == 0 else {
            throw LocalSummaryCommandError.failed
        }
        guard let result = try? JSONDecoder().decode(LocalSummaryResult.self, from: output) else {
            throw LocalSummaryCommandError.invalidResponse
        }
        return result
    }
}
