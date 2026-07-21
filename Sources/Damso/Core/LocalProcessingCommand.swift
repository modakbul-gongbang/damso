import Foundation

struct LocalProcessingCommand: Equatable, Sendable {
    let pythonExecutable: String

    init(pythonExecutable: String = "python3") {
        self.pythonExecutable = pythonExecutable
    }

    var arguments: [String] {
        [pythonExecutable, "-m", "damso.processing", "--request", "-"]
    }
}

struct LocalProcessingRequest: Encodable, Sendable {
    let operation = "phase-one"
    let recordingDirectory: String
    let audioPath: String
    let systemAudioPath: String?
    let hints: LocalProcessingHints

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
        case audioPath = "audio_path"
        case systemAudioPath = "system_audio_path"
        case hints
    }

    init(recordingDirectory: String, audioPath: String, systemAudioPath: String? = nil, hints: LocalProcessingHints) {
        self.recordingDirectory = recordingDirectory
        self.audioPath = audioPath
        self.systemAudioPath = systemAudioPath
        self.hints = hints
    }
}

struct LocalProcessingHints: Encodable, Sendable {
    let participants: [String]
    let topic: String?
    let domainTerms: [String]
    let numSpeakers: Int?

    enum CodingKeys: String, CodingKey {
        case participants
        case topic
        case domainTerms = "domain_terms"
        case numSpeakers = "num_speakers"
    }

    init(_ hints: MeetingHints) {
        participants = hints.participants
        topic = hints.topic
        domainTerms = hints.domainTerms
        numSpeakers = hints.numSpeakers
    }
}

struct LocalProcessingResult: Decodable, Equatable, Sendable {
    let ok: Bool
    let stage: String?
    let speakerCount: Int?
    let processedAudioFile: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case stage
        case speakerCount = "speaker_count"
        case processedAudioFile = "processed_audio_file"
    }

    init(ok: Bool, stage: String?, speakerCount: Int?, processedAudioFile: String? = nil) {
        self.ok = ok
        self.stage = stage
        self.speakerCount = speakerCount
        self.processedAudioFile = processedAudioFile
    }
}

struct LocalSpeakerResolution: Encodable, Sendable {
    let action: String
    let name: String?
    var alias: String?
}

struct LocalResolutionProcessingRequest: Encodable, Sendable {
    let operation = "apply-resolutions"
    let recordingDirectory: String
    let peoplesDirectory: String
    let meetingDate: String
    let resolutions: [String: LocalSpeakerResolution]

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
        case peoplesDirectory = "peoples_directory"
        case meetingDate = "meeting_date"
        case resolutions
    }
}

struct LocalRefreshCandidatesRequest: Encodable, Sendable {
    let operation = "refresh-candidates"
    let recordingDirectory: String
    let peoplesDirectory: String

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
        case peoplesDirectory = "peoples_directory"
    }
}

struct LocalPersonEmailRequest: Encodable, Sendable {
    let operation = "set-person-email"
    let peoplesDirectory: String
    let name: String
    let email: String

    enum CodingKeys: String, CodingKey {
        case operation
        case peoplesDirectory = "peoples_directory"
        case name
        case email
    }
}

struct LocalRemovePersonAliasRequest: Encodable, Sendable {
    let operation = "remove-person-alias"
    let peoplesDirectory: String
    let name: String
    let alias: String

    enum CodingKeys: String, CodingKey {
        case operation
        case peoplesDirectory = "peoples_directory"
        case name
        case alias
    }
}

struct LocalPersonNoteRequest: Encodable, Sendable {
    let operation = "append-person-note"
    let recordingDirectory: String
    let peoplesDirectory: String
    let meetingDate: String
    let name: String
    let note: String

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
        case peoplesDirectory = "peoples_directory"
        case meetingDate = "meeting_date"
        case name
        case note
    }
}

enum LocalProcessingCommandError: Error, Equatable {
    case requestEncoding
    case launchFailed
    case failed
    case backend(code: String, nextAction: String)
    case invalidResponse
    case oversizedResponse
}

private struct LocalProcessingErrorEnvelope: Decodable {
    struct Details: Decodable {
        let code: String
        let nextAction: String

        enum CodingKeys: String, CodingKey {
            case code
            case nextAction = "next_action"
        }
    }

    let ok: Bool
    let error: Details
}

enum LocalProcessingProcessRunner {
    private static let maximumResponseBytes = 64 * 1_024

    static func runPhaseOne(_ request: LocalProcessingRequest, command: LocalProcessingCommand = .init()) throws -> LocalProcessingResult {
        try run(request, command: command)
    }

    static func applyResolutions(_ request: LocalResolutionProcessingRequest, command: LocalProcessingCommand = .init()) throws -> LocalProcessingResult {
        try run(request, command: command)
    }

    static func appendPersonNote(_ request: LocalPersonNoteRequest, command: LocalProcessingCommand = .init()) throws -> LocalProcessingResult {
        try run(request, command: command)
    }

    static func refreshCandidates(_ request: LocalRefreshCandidatesRequest, command: LocalProcessingCommand = .init()) throws -> LocalProcessingResult {
        try run(request, command: command)
    }

    static func setPersonEmail(_ request: LocalPersonEmailRequest, command: LocalProcessingCommand = .init()) throws -> LocalProcessingResult {
        try run(request, command: command)
    }

    static func removePersonAlias(_ request: LocalRemovePersonAliasRequest, command: LocalProcessingCommand = .init()) throws -> LocalProcessingResult {
        try run(request, command: command)
    }

    private static func run<Request: Encodable>(_ request: Request, command: LocalProcessingCommand) throws -> LocalProcessingResult {
        let input: Data
        do {
            input = try JSONEncoder().encode(request)
        } catch {
            throw LocalProcessingCommandError.requestEncoding
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
            throw LocalProcessingCommandError.launchFailed
        }
        standardInput.fileHandleForWriting.write(input)
        try? standardInput.fileHandleForWriting.close()
        process.waitUntilExit()

        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        guard output.count <= maximumResponseBytes else {
            throw LocalProcessingCommandError.oversizedResponse
        }
        guard process.terminationStatus == 0 else {
            if let envelope = try? JSONDecoder().decode(LocalProcessingErrorEnvelope.self, from: output), !envelope.ok {
                throw LocalProcessingCommandError.backend(code: envelope.error.code, nextAction: envelope.error.nextAction)
            }
            throw LocalProcessingCommandError.failed
        }
        guard let result = try? JSONDecoder().decode(LocalProcessingResult.self, from: output), result.ok else {
            throw LocalProcessingCommandError.invalidResponse
        }
        return result
    }
}
