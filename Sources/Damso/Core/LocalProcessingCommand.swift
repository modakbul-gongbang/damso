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

struct LocalReclusterRequest: Encodable, Sendable {
    let operation = "recluster"
    let recordingDirectory: String
    let audioPath: String
    let numSpeakers: Int

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
        case audioPath = "audio_path"
        case numSpeakers = "num_speakers"
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
    /// The mini's `damso.serve` rejected the request's protocol_version.
    /// Surface exactly one message: update Damso on the Mac mini.
    case remoteUpdateRequired
    /// Remote mode is selected but no store root is configured for it.
    case remoteMisconfigured
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

    static func runPhaseOne(_ request: LocalProcessingRequest, command: LocalProcessingCommand = .init(), launcher: CommandLauncher = CommandLauncher()) throws -> LocalProcessingResult {
        try run(request, command: command, launcher: launcher)
    }

    static func applyResolutions(_ request: LocalResolutionProcessingRequest, command: LocalProcessingCommand = .init(), launcher: CommandLauncher = CommandLauncher()) throws -> LocalProcessingResult {
        try run(request, command: command, launcher: launcher)
    }

    static func recluster(_ request: LocalReclusterRequest, command: LocalProcessingCommand = .init(), launcher: CommandLauncher = CommandLauncher()) throws -> LocalProcessingResult {
        try run(request, command: command, launcher: launcher)
    }

    static func appendPersonNote(_ request: LocalPersonNoteRequest, command: LocalProcessingCommand = .init(), launcher: CommandLauncher = CommandLauncher()) throws -> LocalProcessingResult {
        try run(request, command: command, launcher: launcher)
    }

    static func refreshCandidates(_ request: LocalRefreshCandidatesRequest, command: LocalProcessingCommand = .init(), launcher: CommandLauncher = CommandLauncher()) throws -> LocalProcessingResult {
        try run(request, command: command, launcher: launcher)
    }

    static func setPersonEmail(_ request: LocalPersonEmailRequest, command: LocalProcessingCommand = .init(), launcher: CommandLauncher = CommandLauncher()) throws -> LocalProcessingResult {
        try run(request, command: command, launcher: launcher)
    }

    static func removePersonAlias(_ request: LocalRemovePersonAliasRequest, command: LocalProcessingCommand = .init(), launcher: CommandLauncher = CommandLauncher()) throws -> LocalProcessingResult {
        try run(request, command: command, launcher: launcher)
    }

    private static func run<Request: Encodable>(_ request: Request, command: LocalProcessingCommand, launcher: CommandLauncher) throws -> LocalProcessingResult {
        let input: Data
        do {
            input = try JSONEncoder().encode(request)
        } catch {
            throw LocalProcessingCommandError.requestEncoding
        }

        switch launcher.configuration.mode {
        case .local:
            // Unchanged from before the launcher existed: the same argv, the
            // same spawn, the same envelope.
            let output = try spawn(argv: command.arguments, input: input, launcher: launcher)
            return try decode(output)
        case .remote:
            let data: Data
            do {
                data = try DamsoServeClient(launcher: launcher).send(request)
            } catch {
                throw Self.translate(error)
            }
            return try decode(CommandLauncherOutput(data: data, terminationStatus: 0))
        }
    }

    private static func spawn(argv: [String], input: Data, launcher: CommandLauncher) throws -> CommandLauncherOutput {
        do {
            return try launcher.run(argv: argv, input: input, maximumResponseBytes: maximumResponseBytes)
        } catch CommandLauncherError.oversizedResponse {
            throw LocalProcessingCommandError.oversizedResponse
        } catch {
            throw LocalProcessingCommandError.launchFailed
        }
    }

    static func injectProtocolVersion(into data: Data) throws -> Data {
        do {
            return try DamsoServeClient.injectProtocolVersion(into: data)
        } catch {
            throw LocalProcessingCommandError.requestEncoding
        }
    }

    private static func translate(_ error: Error) -> LocalProcessingCommandError {
        switch error {
        case DamsoServeError.remoteMisconfigured: .remoteMisconfigured
        case DamsoServeError.oversizedResponse: .oversizedResponse
        case DamsoServeError.requestEncoding: .requestEncoding
        case DamsoServeError.remoteUpdateRequired: .remoteUpdateRequired
        case DamsoServeError.protocolError: .failed
        case DamsoServeError.launchFailed: .launchFailed
        default: .launchFailed
        }
    }

    /// Order matters: a `damso.serve` protocol-level rejection and a plain
    /// operation error are structurally distinct shapes, so both are tried
    /// before falling back to a successful result. Exit code is not a
    /// reliable signal here - `damso.serve` is a persistent-server boundary
    /// that reports operation failure only in the JSON body, unlike
    /// `damso.processing`'s CLI, which also exits non-zero on failure.
    static func decode(_ output: CommandLauncherOutput) throws -> LocalProcessingResult {
        do {
            try DamsoServeClient.rejectProtocolError(output.data)
        } catch {
            throw Self.translate(error)
        }
        if let envelope = try? JSONDecoder().decode(LocalProcessingErrorEnvelope.self, from: output.data), !envelope.ok {
            throw LocalProcessingCommandError.backend(code: envelope.error.code, nextAction: envelope.error.nextAction)
        }
        guard let result = try? JSONDecoder().decode(LocalProcessingResult.self, from: output.data), result.ok else {
            throw output.terminationStatus == 0 ? LocalProcessingCommandError.invalidResponse : LocalProcessingCommandError.failed
        }
        return result
    }
}
