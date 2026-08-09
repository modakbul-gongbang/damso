import Foundation

enum OutboxHandoffError: Error, Equatable {
    case remoteMisconfigured
    case transferFailed
}

/// The client-Mac implementation of `MeetingStoring`: reads come from a local
/// cache directory kept in sync with the mini's canonical store (R7, T6),
/// writes to an *existing* canonical record go to the mini through
/// `damso.serve` (R1, R3). A brand-new record (recording start through the
/// outbox handoff, R6/T7) instead lands in a local outbox first - it has no
/// canonical counterpart yet for `damso.serve` to write to, and live audio
/// capture must stream to local disk regardless of store mode (D-10: a
/// network path as the recording target risks losing the meeting on a
/// dropped connection). Every read method delegates to a plain `MeetingStore`
/// pointed at the cache or outbox root instead of re-implementing file
/// parsing - both are laid out identically to the canonical store, so the
/// exact same logic that reads the real thing reads either mirror.
/// `@unchecked`: every stored property is immutable and itself either
/// `Sendable` or safe for concurrent read-only use (`cache`/`outbox`, see
/// `MeetingStore`'s own `@unchecked Sendable`); needed so `@MainActor` call
/// sites can call its async methods without a data-race error.
final class RemoteMeetingStore: MeetingStoring, @unchecked Sendable {
    private let launcher: CommandLauncher
    private let client: DamsoServeClient
    /// Read-only from this class's perspective: T6's sync engine owns writing
    /// into it. Never call one of `cache`'s own write methods here.
    private let cache: MeetingStore
    /// This class owns the outbox directly (unlike `cache`): every write to a
    /// not-yet-handed-off record goes through `outbox`'s own `MeetingStore`
    /// methods, reusing its validated staging-then-atomic-move logic as-is.
    private let outbox: MeetingStore
    /// Defaults to the process-wide singleton; tests inject a fresh instance
    /// so a real "mini unreachable" outcome here never leaks into another
    /// test's `connectionStatus` expectations.
    private let tracker: RemoteConnectivityTracker

    init(launcher: CommandLauncher, cacheRoot: URL, outboxRoot: URL, tracker: RemoteConnectivityTracker = .shared) {
        self.launcher = launcher
        self.tracker = tracker
        self.client = DamsoServeClient(launcher: launcher, tracker: tracker)
        self.cache = MeetingStore(root: cacheRoot)
        self.outbox = MeetingStore(root: outboxRoot)
    }

    // MARK: Lifecycle

    var isConfigured: Bool { launcher.configuration.remoteStoreRootPath != nil }

    /// One R7 cache-sync pass (T8): pulls the include-listed metadata
    /// artifacts from the mini into `cache`'s root. A no-op, not an error,
    /// when remote execution isn't configured or the mini is unreachable.
    @discardableResult
    func syncCache() async -> Bool {
        await CacheSyncEngine(launcher: launcher, cacheRoot: cache.rootURL, tracker: tracker).sync()
    }

    func bootstrap() throws {
        // The mini bootstraps the canonical store itself; the client only
        // needs its local cache and outbox directories ready so reads and a
        // new recording don't fail before the first sync/handoff.
        try cache.bootstrap()
        try outbox.bootstrap()
    }

    func health() -> StorageHealth {
        guard isConfigured else {
            return .unavailable("Remote execution is not configured. Set it up in Settings.")
        }
        return cache.health()
    }

    // MARK: Path resolution

    var storeRootPath: String { launcher.configuration.remoteStoreRootPath ?? "" }

    var peoplesDirectoryPath: String {
        CanonicalStoreLayout(root: URL(fileURLWithPath: storeRootPath)).peoples.path
    }

    func recordDirectoryPath(stem: String) -> String {
        CanonicalStoreLayout(root: URL(fileURLWithPath: storeRootPath)).recordDirectory(stem: stem).path
    }

    /// The outbox copy while a record has not been handed off yet (including
    /// while it is actively recording - this is exactly what native capture
    /// streams audio into), the cache mirror once it has.
    func recordDirectoryURL(stem: String) -> URL {
        isOutboxOnly(stem: stem) ? outbox.recordDirectoryURL(stem: stem) : cache.recordDirectoryURL(stem: stem)
    }

    /// A record with no cached (handed-off) counterpart is still outbox-only.
    /// Checking the cache rather than the mini directly keeps every one of
    /// these checks local and instant; the tradeoff (a small race between an
    /// in-flight handoff and the next cache sync) only ever makes a check
    /// answer "still outbox-only" a little late, never causes a wrong write.
    /// Only while the record is still outbox-only. Once handed off, the cache
    /// mirror holds metadata alone - the audio stays on the server and is
    /// pulled on demand - so a local presence check would report a healthy
    /// recording as missing.
    func holdsRecordAudioLocally(stem: String) -> Bool { isOutboxOnly(stem: stem) }

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

    // MARK: Records - creation always starts in the outbox (R6)

    func createRecord(_ draft: MeetingDraft) throws -> MeetingRecord {
        try outbox.createRecord(draft)
    }

    func commit(_ record: MeetingRecord, artifacts: [String: Data]) throws {
        try outbox.commit(record, artifacts: artifacts)
    }

    /// Unreachable in practice: External Sync only ever runs against a local
    /// `MeetingStore` (D-A1/T14 confines it to the machine that owns the
    /// canonical store), so this path exists only to satisfy the protocol.
    /// Implemented for real rather than left throwing, since "unreachable
    /// today" is not the same guarantee as "unreachable forever."
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

    // MARK: Outbox handoff (R6/T7)

    /// Transfers one outbox record to the mini: rsync the outbox record
    /// directory's contents into the mini's `.staging`, then atomically
    /// promote it with `commit-record`. Idempotent in effect - a record with
    /// no outbox copy left (already handed off) is treated as a no-op
    /// success so a retry sweep never needs to track handoff state itself.
    @discardableResult
    func handOff(stem: String) async throws -> Bool {
        let outboxDirectory = outbox.recordDirectoryURL(stem: stem)
        guard FileManager.default.fileExists(atPath: outboxDirectory.path) else {
            return false
        }
        guard case .remote(let host, _) = launcher.configuration.mode else {
            throw OutboxHandoffError.remoteMisconfigured
        }
        let stagingPath = storeRootPath + "/.staging/" + UUID().uuidString
        try await push(host: host, from: outboxDirectory, to: stagingPath)
        try sendRecordOperation(CommitRecordRequest(stagingDirectory: stagingPath, recordingDirectory: recordDirectoryPath(stem: stem)))
        return true
    }

    /// One idempotent pass over outbox state, meant to be called after a
    /// recording stops and by T9's periodic sweep so a handoff interrupted by
    /// a disconnected mini resumes automatically once the connection is back
    /// (R6, R9), without a live reconnect listener of its own: every step
    /// here is safe to repeat and does nothing when there is nothing to do.
    func retryPendingOutboxWork() async {
        guard let stems = try? outboxStems() else { return }
        for stem in stems {
            if (try? cache.load(stem: stem)) == nil {
                _ = try? await handOff(stem: stem)
            }
            deleteOutboxAudioIfPhaseOneComplete(stem: stem)
        }
    }

    /// Deletes only the outbox's audio copy for `stem`, and only once the
    /// synced cache confirms phase-one completed on the mini (R6) - never
    /// the meeting.json or hints, and never based on a local guess. Safe to
    /// call before the cache has synced far enough to know: it just returns
    /// false and changes nothing.
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

    /// R9(d)'s "전송 대기 N건": outbox records that have not reached the
    /// mini's cache yet, mirroring `retryPendingOutboxWork`'s own predicate
    /// so the count and the sweep that clears it never disagree. Excludes a
    /// record that has been handed off but is still waiting on the
    /// audio-deletion gate - that one is no longer "pending transfer".
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

    /// rsync does not reliably shell-quote spaces in a remote-path argument;
    /// a literal backslash-space is required (`RemoteAudioFetcher.pull`'s
    /// same pitfall, mirrored here for the push direction). The trailing
    /// slash on the source path copies the outbox record's *contents* into
    /// the staging directory, not the directory itself nested one level deep.
    private func push(host: String, from localDirectory: URL, to remotePath: String) async throws {
        let escapedRemotePath = remotePath.replacingOccurrences(of: " ", with: "\\ ")
        let succeeded = await Task.detached(priority: .utility) { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["rsync", "-a", CommandLauncher.rsyncRemoteShellArgument, localDirectory.path + "/", "\(host):\(escapedRemotePath)/"]
            process.environment = ProcessRuntime.environment()
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return false
            }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        tracker.noteTransferResult(succeeded: succeeded)
        guard succeeded else {
            throw OutboxHandoffError.transferFailed
        }
    }

    // MARK: People - reads mirror the cache, writes go through damso.serve

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

    /// Cache-only for now: `damso.speaker_hints` has no persistence of its
    /// own (Swift always wrote this file directly, unlike `damso.summary`
    /// which writes `summary.json` itself) and there is no `damso.serve`
    /// operation for it yet. The next rsync from the mini overwrites this
    /// local write, costing one re-run of the regenerable hints agent - a
    /// documented gap, not silent data loss, since nothing authoritative
    /// lives only here.
    func writeSpeakerSuggestions(_ suggestions: [SpeakerSuggestion], stem: String) {
        cache.writeSpeakerSuggestions(suggestions, stem: stem)
    }

    func hasCleanupOverlay(stem: String) -> Bool { cache.hasCleanupOverlay(stem: stem) }
    func storedSummary(stem: String) throws -> StructuredSummary? { try cache.storedSummary(stem: stem) }
    func storedSummaryArtifact(stem: String) throws -> StoredSummaryArtifact? { try cache.storedSummaryArtifact(stem: stem) }

    // MARK: damso.serve request plumbing

    private func sendRecordOperation(_ request: some Encodable) throws {
        _ = try send(request) as OKResponse
    }

    private func send<Response: Decodable>(_ request: some Encodable) throws -> Response {
        let data = try client.send(request)
        return try DamsoServeClient.decode(data, as: Response.self)
    }
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

struct CommitRecordRequest: Encodable {
    let operation = "commit-record"
    let stagingDirectory: String
    let recordingDirectory: String

    enum CodingKeys: String, CodingKey {
        case operation
        case stagingDirectory = "staging_directory"
        case recordingDirectory = "recording_directory"
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
