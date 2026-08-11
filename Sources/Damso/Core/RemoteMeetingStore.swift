import Foundation

enum OutboxHandoffError: Error, Equatable {
    case remoteMisconfigured
    case transferFailed
}

/// The one `MeetingStoring` implementation the app now uses, local or
/// remote (D-05: "local 모드도 HTTP 루프백으로 동일 구조") - reads and writes
/// always go through the server daemon's `/v1` API (`DamsoHTTPClient`), never
/// direct `MeetingStore` file access, except for the two directories this
/// class owns itself: the outbox (a brand-new record has no server
/// counterpart yet, D-10) and, in remote mode only, the local read cache
/// (D-15). In local mode `cacheRoot` *is* the real canonical store directory
/// - the daemon and this app share one disk, so there is nothing to mirror
/// and `needsCacheSync` is false; in remote mode it is a separate mirror
/// directory kept in sync with `/v1/changes`.
final class RemoteMeetingStore: MeetingStoring, @unchecked Sendable {
    private let client: DamsoHTTPClient
    private let connectionConfiguration: ServerConnectionConfiguration
    private let needsCacheSync: Bool
    /// Read-only from this class's perspective in remote mode (the changes
    /// sync owns writing into it); in local mode this literally is the
    /// canonical store, so any write reaching `cache` through `MeetingStore`
    /// methods would be a real, direct canonical write - never call one of
    /// `cache`'s own write methods here regardless of mode.
    private let cache: MeetingStore
    private let outbox: MeetingStore
    private let tracker: RemoteConnectivityTracker
    private var lastSyncCursor: String?

    init(
        client: DamsoHTTPClient,
        connectionConfiguration: ServerConnectionConfiguration,
        cacheRoot: URL,
        outboxRoot: URL,
        needsCacheSync: Bool,
        tracker: RemoteConnectivityTracker = .shared
    ) {
        self.client = client
        self.connectionConfiguration = connectionConfiguration
        self.needsCacheSync = needsCacheSync
        self.tracker = tracker
        self.cache = MeetingStore(root: cacheRoot)
        self.outbox = MeetingStore(root: outboxRoot)
    }

    /// True only when this instance talks to a genuinely remote daemon (a
    /// different machine); false in local mode, where `cache` already is the
    /// canonical store and "not yet transferred" cannot apply.
    var isRemoteConnection: Bool { needsCacheSync }

    // MARK: Lifecycle

    var isConfigured: Bool {
        switch connectionConfiguration.mode {
        case .local:
            FileManager.default.fileExists(atPath: cache.rootURL.path)
        case .remote:
            connectionConfiguration.remoteStoreRootPath != nil
        }
    }

    /// D-15's incremental changelist sync: a no-op returning `true`
    /// immediately in local mode (the "cache" already is the canonical
    /// store), otherwise pulls everything `/v1/changes` reports changed
    /// since the last cursor.
    @discardableResult
    func syncCache() async -> Bool {
        guard needsCacheSync else { return true }
        guard case .remote = connectionConfiguration.mode else { return false }
        do {
            try FileManager.default.createDirectory(at: cache.rootURL, withIntermediateDirectories: true)
            let data = try client.changes(since: lastSyncCursor)
            let response = try DamsoHTTPClient.decode(data, as: ChangesResponse.self)
            for recording in response.recordings {
                for filename in CacheSyncFileNames.perRecording {
                    try? client.downloadFile(
                        stem: recording.stem,
                        filename: filename,
                        to: cache.rootURL.appendingPathComponent("Plaud/recordings/\(recording.stem)/\(filename)")
                    )
                }
            }
            lastSyncCursor = response.cursor
            tracker.noteSuccess()
            return true
        } catch let error as DamsoServerError {
            tracker.noteFailure(error)
            return false
        } catch {
            return false
        }
    }

    func bootstrap() throws {
        // The daemon bootstraps the canonical store itself; the client only
        // needs its own outbox (and, remotely, its cache) directories ready.
        if needsCacheSync {
            try cache.bootstrap()
        }
        try outbox.bootstrap()
    }

    func health() -> StorageHealth {
        guard isConfigured else {
            return .unavailable("Server storage is not configured. Set it up in Settings.")
        }
        return needsCacheSync ? cache.health() : cache.health()
    }

    // MARK: Path resolution

    var storeRootPath: String {
        switch connectionConfiguration.mode {
        case .local:
            cache.rootURL.path
        case .remote:
            connectionConfiguration.remoteStoreRootPath ?? ""
        }
    }

    /// Always the local cache mirror, never `storeRootPath` - in remote mode
    /// that string is the server's own filesystem path (see D-08/D-15), which
    /// this Mac cannot write to.
    var localRootURL: URL { cache.rootURL }

    var peoplesDirectoryPath: String {
        CanonicalStoreLayout(root: URL(fileURLWithPath: storeRootPath)).peoples.path
    }

    func recordDirectoryPath(stem: String) -> String {
        CanonicalStoreLayout(root: URL(fileURLWithPath: storeRootPath)).recordDirectory(stem: stem).path
    }

    func recordDirectoryURL(stem: String) -> URL {
        isOutboxOnly(stem: stem) ? outbox.recordDirectoryURL(stem: stem) : cache.recordDirectoryURL(stem: stem)
    }

    /// Local mode: always true, since the "cache" is the real store and every
    /// committed record's audio is right there. Remote mode: only while the
    /// record has not been handed off, or once its audio has been pulled
    /// on demand (D-15 excludes audio from the periodic sync by design).
    func holdsRecordAudioLocally(stem: String) -> Bool {
        guard needsCacheSync else { return true }
        return isOutboxOnly(stem: stem)
    }

    private func isOutboxOnly(stem: String) -> Bool {
        FileManager.default.fileExists(atPath: outbox.recordDirectoryURL(stem: stem).path) && (try? cache.load(stem: stem)) == nil
    }

    // MARK: Records - reads merge the outbox (not yet handed off) and the cache

    func load(stem: String) throws -> MeetingRecord {
        if let cached = try? cache.load(stem: stem) {
            return cached
        }
        return try outbox.load(stem: stem)
    }

    func list() throws -> [MeetingRecord] {
        let cached = try cache.list()
        let cachedStems = Set(cached.map(\.stem))
        let outboxOnly = ((try? outbox.list()) ?? []).filter { !cachedStems.contains($0.stem) }
        return (cached + outboxOnly).sorted { $0.createdAt > $1.createdAt }
    }

    func checksum(stem: String) throws -> String {
        isOutboxOnly(stem: stem) ? try outbox.checksum(stem: stem) : try cache.checksum(stem: stem)
    }

    // MARK: Records - creation always starts in the outbox (D-10: live capture streams to local disk regardless of mode)

    func createRecord(_ draft: MeetingDraft) throws -> MeetingRecord {
        try outbox.createRecord(draft)
    }

    func commit(_ record: MeetingRecord, artifacts: [String: Data]) throws {
        try outbox.commit(record, artifacts: artifacts)
    }

    func commitImported(_ record: MeetingRecord, movingAudioFrom audioURL: URL) throws {
        try outbox.commitImported(record, movingAudioFrom: audioURL)
    }

    // MARK: Records - mutation routes to wherever the record currently lives

    func update(_ record: MeetingRecord) throws {
        if isOutboxOnly(stem: record.stem) {
            try outbox.update(record)
            return
        }
        try sendRecordOperation(UpdateRecordRequest(recordingDirectory: recordDirectoryPath(stem: record.stem), record: record))
    }

    func delete(stem: String) throws {
        if isOutboxOnly(stem: stem) {
            try outbox.delete(stem: stem)
            return
        }
        try sendRecordOperation(DeleteRecordRequest(recordingDirectory: recordDirectoryPath(stem: stem)))
    }

    func quarantine(stem: String, reason: String) throws {
        if isOutboxOnly(stem: stem) {
            try outbox.quarantine(stem: stem, reason: reason)
            return
        }
        try sendRecordOperation(QuarantineRecordRequest(recordingDirectory: recordDirectoryPath(stem: stem), reason: reason))
    }

    func invalidatePhaseOneDependents(stem: String) throws {
        if isOutboxOnly(stem: stem) {
            try outbox.invalidatePhaseOneDependents(stem: stem)
            return
        }
        try sendRecordOperation(InvalidatePhaseOneDependentsRequest(recordingDirectory: recordDirectoryPath(stem: stem)))
    }

    func invalidateCleanupOverlay(stem: String) throws {
        if isOutboxOnly(stem: stem) {
            try outbox.invalidateCleanupOverlay(stem: stem)
            return
        }
        try sendRecordOperation(InvalidateCleanupOverlayRequest(recordingDirectory: recordDirectoryPath(stem: stem)))
    }

    // MARK: Outbox handoff (D-06, D-23): archive upload replaces rsync push + commit-record

    /// Packs the outbox record directory into a tar.gz archive and uploads it
    /// in one request; the server extracts, validates, and atomically commits
    /// it (`/v1/recordings`), then auto-enqueues phase-one (D-13). An
    /// interrupted upload fails cleanly and nothing is committed - retry means
    /// "upload the whole archive again" (D-23), and the outbox copy this
    /// method reads from is untouched until that succeeds. Idempotent in
    /// effect - a record with no outbox copy left is a no-op success.
    @discardableResult
    func handOff(stem: String) async throws -> Bool {
        let outboxDirectory = outbox.recordDirectoryURL(stem: stem)
        guard FileManager.default.fileExists(atPath: outboxDirectory.path) else {
            return false
        }
        guard isConfigured else {
            throw OutboxHandoffError.remoteMisconfigured
        }
        let archiveData: Data
        do {
            archiveData = try RecordingArchiver.archive(directory: outboxDirectory)
        } catch {
            throw OutboxHandoffError.transferFailed
        }
        let succeeded = await Task.detached(priority: .utility) { [client] in
            (try? client.uploadRecording(archiveData: archiveData)) != nil
        }.value
        tracker.noteTransferResult(succeeded: succeeded)
        guard succeeded else {
            throw OutboxHandoffError.transferFailed
        }
        return true
    }

    /// One idempotent pass over outbox state (D-23 retry, R9): a handoff
    /// interrupted by a disconnected server resumes automatically once the
    /// connection is back, without a live reconnect listener of its own.
    func retryPendingOutboxWork() async {
        guard let stems = try? outboxStems() else { return }
        for stem in stems {
            if (try? cache.load(stem: stem)) == nil {
                _ = try? await handOff(stem: stem)
            }
            deleteOutboxAudioIfPhaseOneComplete(stem: stem)
        }
    }

    @discardableResult
    func deleteOutboxAudioIfPhaseOneComplete(stem: String) -> Bool {
        guard cache.hasPhaseOneTranscript(stem: stem), let record = try? outbox.load(stem: stem) else {
            return false
        }
        let directory = outbox.recordDirectoryURL(stem: stem)
        for name in [record.originalAudioFile, record.systemAudioFile, record.processedAudioFile].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        return true
    }

    func outboxPendingCount() -> Int {
        (try? outboxStems())?.filter { (try? cache.load(stem: $0)) == nil }.count ?? 0
    }

    private func outboxStems() throws -> [String] {
        let recordings = CanonicalStoreLayout(root: outbox.rootURL).recordings
        guard FileManager.default.fileExists(atPath: recordings.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: recordings, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map(\.lastPathComponent)
    }

    // MARK: Processing (D-13): trigger + poll, not spawn-and-wait

    /// Uploads a just-stopped recording and lets the server's queue take it
    /// from there (D-13). Replaces the SSH-era direct `runPhaseOne` call.
    func triggerProcessing(stem: String) async throws {
        _ = try await handOff(stem: stem)
    }

    func processingStatus(stem: String) async throws -> ProcessingStatusResponse {
        let data = try await Task.detached(priority: .utility) { [client] in
            try client.status(stem: stem)
        }.value
        return try DamsoHTTPClient.decode(data, as: ProcessingStatusResponse.self)
    }

    func requeueProcessing(stem: String) async throws {
        _ = try await Task.detached(priority: .utility) { [client] in
            try client.requeue(stem: stem)
        }.value
    }

    func triggerSummary(stem: String, agent: String, language: String, meetingDate: String?) async throws {
        _ = try await Task.detached(priority: .utility) { [client] in
            try client.triggerSummary(stem: stem, agent: agent, language: language, meetingDate: meetingDate)
        }.value
    }

    /// Fetches one file directly (metadata or audio alike, D-15) - used
    /// on-demand rather than through the periodic changes sync, e.g. to
    /// confirm and pull a freshly produced `combined-audio.m4a`.
    func pullFile(stem: String, filename: String, to destination: URL) async throws {
        try await Task.detached(priority: .utility) { [client] in
            try client.downloadFile(stem: stem, filename: filename, to: destination)
        }.value
    }

    // MARK: People - reads mirror the cache, writes go through the server API

    func listPeople(records: [MeetingRecord]) throws -> [LocalPersonProfile] { try cache.listPeople(records: records) }
    func profileNotes(name: String) -> String? { cache.profileNotes(name: name) }
    func profileEmail(name: String) -> String? { cache.profileEmail(name: name) }

    func mergeProfiles(primaryName: String, absorbedName: String) throws -> ProfileMergeOutcome {
        let request = MergeProfilesRequest(peoplesDirectory: peoplesDirectoryPath, primaryName: primaryName, absorbedName: absorbedName)
        let response: MergeProfilesResponse = try send(request)
        return ProfileMergeOutcome(primaryName: primaryName, absorbedName: absorbedName, archiveDirectory: URL(fileURLWithPath: response.archiveDirectory))
    }

    func deletePerson(named name: String, aliases: [String]) throws -> ProfileDeleteOutcome {
        let request = DeletePersonRequest(peoplesDirectory: peoplesDirectoryPath, name: name, aliases: aliases)
        let response: DeletePersonResponse = try send(request)
        return ProfileDeleteOutcome(name: name, archiveDirectory: response.archiveDirectory.map { URL(fileURLWithPath: $0) })
    }

    func unmarkPersonDeleted(_ name: String) {
        let request = UnmarkPersonDeletedRequest(peoplesDirectory: peoplesDirectoryPath, name: name)
        _ = try? send(request) as OKResponse
    }

    // MARK: Processing artifacts - reads mirror the cache

    func processingArtifacts(stem: String) throws -> MeetingProcessingArtifacts { try cache.processingArtifacts(stem: stem) }
    func hasPhaseOneTranscript(stem: String) -> Bool { cache.hasPhaseOneTranscript(stem: stem) }
    func hasCompletePhaseOneReviewArtifacts(stem: String) -> Bool { cache.hasCompletePhaseOneReviewArtifacts(stem: stem) }
    func cachedSpeakerSuggestions(stem: String) -> [String: [SpeakerSuggestion]] { cache.cachedSpeakerSuggestions(stem: stem) }
    func hasCachedSpeakerSuggestions(stem: String) -> Bool { cache.hasCachedSpeakerSuggestions(stem: stem) }

    func writeSpeakerSuggestions(_ suggestions: [SpeakerSuggestion], stem: String) {
        cache.writeSpeakerSuggestions(suggestions, stem: stem)
    }

    func hasCleanupOverlay(stem: String) -> Bool { cache.hasCleanupOverlay(stem: stem) }
    func storedSummary(stem: String) throws -> StructuredSummary? { try cache.storedSummary(stem: stem) }
    func storedSummaryArtifact(stem: String) throws -> StoredSummaryArtifact? { try cache.storedSummaryArtifact(stem: stem) }

    // MARK: /v1/rpc request plumbing

    private func sendRecordOperation(_ request: some Encodable) throws {
        _ = try send(request) as OKResponse
    }

    private func send<Response: Decodable>(_ request: some Encodable) throws -> Response {
        let data = try client.send(request)
        return try DamsoHTTPClient.decode(data, as: Response.self)
    }
}

enum CacheSyncFileNames {
    /// Mirrors the SSH-era `CacheSyncEngine.includedFileNames`: metadata
    /// only, never audio (D-15 keeps audio on-demand-only).
    static let perRecording = [
        "meeting.json",
        "transcript.raw.json",
        "transcript.json",
        "transcript.md",
        "transcript.cleaned.json",
        "identification.json",
        "summary.json",
        "speaker_hints.json",
        "resolutions.yaml",
        "hint.json",
        "participants.json",
    ]
}

struct ChangesResponse: Decodable {
    struct Entry: Decodable {
        let stem: String
    }
    let cursor: String
    let recordings: [Entry]
}

struct ProcessingStatusResponse: Decodable {
    let stem: String
    let state: String
    let kind: String?
    let error: String?
}

struct OKResponse: Decodable {
    let ok: Bool
}

struct UpdateRecordRequest: Encodable {
    let operation = "update-record"
    let recordingDirectory: String
    let record: MeetingRecord

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
        case record
    }
}

struct DeleteRecordRequest: Encodable {
    let operation = "delete-record"
    let recordingDirectory: String

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
    }
}

struct QuarantineRecordRequest: Encodable {
    let operation = "quarantine-record"
    let recordingDirectory: String
    let reason: String

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
        case reason
    }
}

struct InvalidatePhaseOneDependentsRequest: Encodable {
    let operation = "invalidate-phase-one-dependents"
    let recordingDirectory: String

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
    }
}

struct InvalidateCleanupOverlayRequest: Encodable {
    let operation = "invalidate-cleanup-overlay"
    let recordingDirectory: String

    enum CodingKeys: String, CodingKey {
        case operation
        case recordingDirectory = "recording_directory"
    }
}

struct MergeProfilesRequest: Encodable {
    let operation = "merge-profiles"
    let peoplesDirectory: String
    let primaryName: String
    let absorbedName: String

    enum CodingKeys: String, CodingKey {
        case operation
        case peoplesDirectory = "peoples_directory"
        case primaryName = "primary_name"
        case absorbedName = "absorbed_name"
    }
}

struct MergeProfilesResponse: Decodable {
    let ok: Bool
    let archiveDirectory: String

    enum CodingKeys: String, CodingKey {
        case ok
        case archiveDirectory = "archive_directory"
    }
}

struct DeletePersonRequest: Encodable {
    let operation = "delete-person"
    let peoplesDirectory: String
    let name: String
    let aliases: [String]

    enum CodingKeys: String, CodingKey {
        case operation
        case peoplesDirectory = "peoples_directory"
        case name
        case aliases
    }
}

struct DeletePersonResponse: Decodable {
    let ok: Bool
    let archiveDirectory: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case archiveDirectory = "archive_directory"
    }
}

struct UnmarkPersonDeletedRequest: Encodable {
    let operation = "unmark-person-deleted"
    let peoplesDirectory: String
    let name: String

    enum CodingKeys: String, CodingKey {
        case operation
        case peoplesDirectory = "peoples_directory"
        case name
    }
}
