import Foundation

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

/// D-13: phase-one is no longer a request/response call from the client's
/// side at all - the server's queue runs it after an upload commits. This
/// type only remains as the shape `MeetingWorkspaceController` used to build
/// before an upload, kept for the hints it carries into `meeting.json`;
/// there is no more direct phase-one RPC.
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

/// Undo for an automatically applied note: the app writes summary notes to
/// the profile without asking, so the meeting view offers a per-note removal
/// that has to reach the same profile file.
struct LocalRemovePersonNoteRequest: Encodable, Sendable {
    let operation = "remove-person-note"
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
    case remoteUpdateRequired
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

/// The nine synchronous processing/people RPC operations (D-13 leaves these
/// unchanged in shape - only phase-one and summary became queue-based):
/// recluster, apply-resolutions, append-person-note, refresh-candidates,
/// set-person-email, remove-person-alias, all now POSTed to `/v1/rpc`
/// instead of ssh'd or spawned as a local subprocess (D-05 unifies local and
/// remote onto the same HTTP transport).
enum LocalProcessingProcessRunner {
    static func applyResolutions(_ request: LocalResolutionProcessingRequest, client: DamsoHTTPClient = DamsoHTTPClient()) throws -> LocalProcessingResult {
        try run(request, client: client)
    }

    /// A first re-split of an older meeting re-runs diarization over the
    /// whole recording server-side and can legitimately take a few minutes
    /// (the recluster banner's own copy warns the user of this); every other
    /// operation here is plain local file I/O and stays on `run`'s fast
    /// default.
    static let reclusterTimeout: TimeInterval = 600

    static func recluster(_ request: LocalReclusterRequest, client: DamsoHTTPClient = DamsoHTTPClient()) throws -> LocalProcessingResult {
        try run(request, client: client, timeout: reclusterTimeout)
    }

    static func appendPersonNote(_ request: LocalPersonNoteRequest, client: DamsoHTTPClient = DamsoHTTPClient()) throws -> LocalProcessingResult {
        try run(request, client: client)
    }

    static func removePersonNote(_ request: LocalRemovePersonNoteRequest, client: DamsoHTTPClient = DamsoHTTPClient()) throws -> LocalProcessingResult {
        try run(request, client: client)
    }

    static func refreshCandidates(_ request: LocalRefreshCandidatesRequest, client: DamsoHTTPClient = DamsoHTTPClient()) throws -> LocalProcessingResult {
        try run(request, client: client)
    }

    static func setPersonEmail(_ request: LocalPersonEmailRequest, client: DamsoHTTPClient = DamsoHTTPClient()) throws -> LocalProcessingResult {
        try run(request, client: client)
    }

    static func removePersonAlias(_ request: LocalRemovePersonAliasRequest, client: DamsoHTTPClient = DamsoHTTPClient()) throws -> LocalProcessingResult {
        try run(request, client: client)
    }

    private static func run<Request: Encodable>(_ request: Request, client: DamsoHTTPClient, timeout: TimeInterval = DamsoHTTPClient.defaultTimeout) throws -> LocalProcessingResult {
        let data: Data
        do {
            data = try client.send(request, timeout: timeout)
        } catch {
            throw translate(error)
        }
        return try decode(data)
    }

    private static func translate(_ error: Error) -> LocalProcessingCommandError {
        switch error {
        case DamsoServerError.remoteMisconfigured: .remoteMisconfigured
        case DamsoServerError.payloadTooLarge: .oversizedResponse
        case DamsoServerError.requestEncoding: .requestEncoding
        case DamsoServerError.remoteUpdateRequired: .remoteUpdateRequired
        case DamsoServerError.unprocessable: .failed
        case DamsoServerError.transportFailed: .launchFailed
        default: .launchFailed
        }
    }

    static func decode(_ data: Data) throws -> LocalProcessingResult {
        if let envelope = try? JSONDecoder().decode(LocalProcessingErrorEnvelope.self, from: data), !envelope.ok {
            throw LocalProcessingCommandError.backend(code: envelope.error.code, nextAction: envelope.error.nextAction)
        }
        guard let result = try? JSONDecoder().decode(LocalProcessingResult.self, from: data), result.ok else {
            throw LocalProcessingCommandError.invalidResponse
        }
        return result
    }
}
