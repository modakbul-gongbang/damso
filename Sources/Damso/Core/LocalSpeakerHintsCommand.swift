import Foundation

struct LocalSpeakerHintsCommand: Equatable, Sendable {
    let pythonExecutable: String

    init(pythonExecutable: String = "python3") {
        self.pythonExecutable = pythonExecutable
    }

    var arguments: [String] {
        [pythonExecutable, "-m", "damso.speaker_hints", "--request", "-"]
    }
}

struct LocalSpeakerHintsRequest: Encodable, Sendable {
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

/// One agent-proposed speaker identity. Suggestions never mutate the record;
/// selecting one goes through the same explicit confirmation as any manual
/// choice.
struct SpeakerSuggestion: Codable, Equatable, Identifiable, Sendable {
    var speaker: String
    var name: String
    var confidence: Double
    var reason: String

    var id: String { "\(speaker)|\(name)" }
}

/// The persisted speaker-hints artifact (`speaker_hints.json`), written once
/// when the transcript-reading agent finishes so the "what this speaker talked
/// about" hints are on the cards the moment the meeting is opened, instead of
/// re-running the agent on every open.
struct StoredSpeakerHints: Codable, Equatable, Sendable {
    var version: Int = 1
    var suggestions: [SpeakerSuggestion]
}

struct LocalSpeakerHintsResult: Decodable, Equatable, Sendable {
    let ok: Bool
    let status: String?
    let errorCode: String?
    let suggestions: [SpeakerSuggestion]?

    enum CodingKeys: String, CodingKey {
        case ok
        case status
        case errorCode = "error_code"
        case suggestions
    }
}

enum LocalSpeakerHintsCommandError: Error, Equatable {
    case requestEncoding
    case launchFailed
    case failed
    case invalidResponse
    case oversizedResponse
}

enum LocalSpeakerHintsProcessRunner {
    private static let maximumResponseBytes = 64 * 1_024

    static func run(_ request: LocalSpeakerHintsRequest, command: LocalSpeakerHintsCommand = .init(), launcher: CommandLauncher = CommandLauncher()) throws -> LocalSpeakerHintsResult {
        let input: Data
        do {
            input = try JSONEncoder().encode(request)
        } catch {
            throw LocalSpeakerHintsCommandError.requestEncoding
        }

        let argv: [String]
        switch launcher.configuration.mode {
        case .local:
            argv = command.arguments
        case .remote:
            argv = launcher.argv(module: "damso.speaker_hints", moduleArguments: ["--request", "-"])
        }

        let output: CommandLauncherOutput
        do {
            output = try launcher.run(argv: argv, input: input, maximumResponseBytes: maximumResponseBytes)
        } catch CommandLauncherError.oversizedResponse {
            throw LocalSpeakerHintsCommandError.oversizedResponse
        } catch {
            throw LocalSpeakerHintsCommandError.launchFailed
        }

        guard output.terminationStatus == 0 else {
            throw LocalSpeakerHintsCommandError.failed
        }
        guard let result = try? JSONDecoder().decode(LocalSpeakerHintsResult.self, from: output.data) else {
            throw LocalSpeakerHintsCommandError.invalidResponse
        }
        return result
    }
}
