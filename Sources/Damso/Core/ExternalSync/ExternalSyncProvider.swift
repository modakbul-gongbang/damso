import Foundation

/// Account state of one external recording service as seen from this Mac.
/// The sidebar rows and the Settings tab render exactly these four states.
enum ExternalSyncAccountState: Equatable, Sendable {
    /// The provider's tooling is missing; `guidance` is the install command
    /// or instruction shown in Settings.
    case notInstalled(guidance: String)
    case needsLogin
    case connected
    case error(String)
}

/// One recording as listed by the remote service. Only `remoteID` and
/// `startedAt` are required; a missing title falls back to the date-based
/// display title and the duration is recomputed from the downloaded audio.
struct ExternalRecording: Equatable, Sendable {
    let remoteID: String
    let title: String?
    let startedAt: Date
    let duration: TimeInterval?

    init(remoteID: String, title: String? = nil, startedAt: Date, duration: TimeInterval? = nil) {
        self.remoteID = remoteID
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
    }
}

enum ExternalSyncProviderError: Error, Equatable {
    case notInstalled
    case needsLogin
    case transientFailure(String)
}

/// One external recording service (Plaud today). The sync engine, scheduler
/// wiring, sidebar, and Settings depend only on this protocol, so adding a
/// new service means adding a provider implementation, not new UI or engine
/// structure (R3, R10).
protocol ExternalSyncProvider: Sendable {
    /// Stable, filesystem-safe identifier (checkpoint file name, stem prefix).
    var id: String { get }
    var displayName: String { get }

    func accountState() async -> ExternalSyncAccountState

    /// Starts the provider-owned interactive login (browser OAuth for the
    /// Plaud CLI). Returns when login finished or throws on failure/timeout.
    func beginLogin() async throws

    /// Ends the provider session; credentials stay owned by the provider's
    /// own tooling and are never stored by the app.
    func logout() async throws

    /// Lists recordings whose start time is on or after `since`, newest data
    /// source first is allowed; the engine sorts before importing.
    func listRecordings(since: Date) async throws -> [ExternalRecording]

    /// Downloads the audio for one recording into `directory` and returns the
    /// written file URL (the provider picks the correct file extension).
    func downloadAudio(remoteID: String, into directory: URL) async throws -> URL
}
