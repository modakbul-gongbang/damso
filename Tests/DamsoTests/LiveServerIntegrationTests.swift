import Foundation
import Testing
@testable import Damso

/// T7/T8/AC1/AC2/D-08: real-process, real-socket integration tests for the
/// HTTP daemon's client-side surface (token auth, local daemon lifecycle,
/// remote pairing preflight) - split across this file,
/// `LocalServerLifecycleTests.swift`, and
/// `RemoteExecutionSettingsControllerTests.swift` by subject, but declared
/// as ONE `@Suite(.serialized)` type spanning all three files: each test
/// spawns a real `damso.server.main` subprocess and binds real sockets, and
/// this sandbox does not have the headroom to run many of those
/// concurrently alongside the rest of `swift test --parallel` - three
/// separately-parallel suites reproduced a multi-minute stall system-wide
/// (confirmed by re-running the other ~200 tests alone, which pass in under
/// a second) that a single serialized suite does not.
///
/// Since ADR 0003 the bearer token is the only credential and the transport
/// is plain HTTP, so these run it against the actual `damso-server` process
/// rather than a mock: a token check that only ever sees a mocked response
/// cannot catch a change in how the real middleware answers.
@Suite(.serialized)
struct LiveServerIntegrationTests {
    /// R1/R2/AC1/AC2: off-loopback the daemon serves plain HTTP and demands
    /// the token; there is no TLS listener to fall back to, and the app's own
    /// client is the one making the request.
    @Test
    func remoteClientReachesThePlainHTTPServerWithItsTokenAndIsRefusedWithout() async throws {
        let server = try LiveDamsoServerProcess.start(host: "0.0.0.0")
        defer { server.stop() }
        let credentials = try #require(server.credentials)

        let session = URLSession(configuration: .ephemeral)
        var authorized = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/changes")!, timeoutInterval: 10)
        authorized.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        let (_, okResponse) = try await dataWithHardTimeout(session: session, request: authorized)
        #expect((okResponse as? HTTPURLResponse)?.statusCode == 200)

        let anonymous = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/changes")!, timeoutInterval: 10)
        let (_, refusedResponse) = try await dataWithHardTimeout(session: session, request: anonymous)
        #expect((refusedResponse as? HTTPURLResponse)?.statusCode == 401)
    }

    /// R7/AC7: the whole point of dropping the self-signed certificate - an
    /// ordinary MCP client reaches `/mcp` with a URL and a header, with no
    /// certificate trust to inject and no host alias to invent. `initialize`
    /// is checked first because it is the call that decides whether a client
    /// attaches at all; `tools/list` then proves the session actually works.
    @Test
    func mcpEndpointAnswersOverPlainHTTPWithOnlyATokenHeader() async throws {
        let server = try LiveDamsoServerProcess.start(host: "0.0.0.0")
        defer { server.stop() }
        let credentials = try #require(server.credentials)

        func mcpRequest(_ body: [String: Any], authorized: Bool = true) throws -> URLRequest {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/mcp")!, timeoutInterval: 10)
            request.httpMethod = "POST"
            if authorized {
                request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            }
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            return request
        }

        let session = URLSession(configuration: .ephemeral)

        let initialize: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:] as [String: String],
                "clientInfo": ["name": "damso-tests", "version": "0"]
            ]
        ]
        let (_, initializeResponse) = try await dataWithHardTimeout(session: session, request: try mcpRequest(initialize))
        #expect((initializeResponse as? HTTPURLResponse)?.statusCode == 200)

        let (_, unauthorizedResponse) = try await dataWithHardTimeout(
            session: session,
            request: try mcpRequest(initialize, authorized: false)
        )
        #expect((unauthorizedResponse as? HTTPURLResponse)?.statusCode == 401)

        let toolsList: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:] as [String: String]]
        let (data, response) = try await dataWithHardTimeout(session: session, request: try mcpRequest(toolsList))
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let result = payload?["result"] as? [String: Any]
        let tools = (result?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        #expect(Set(tools) == ["search_meetings", "get_meeting", "get_speaker", "search_people"])
    }

    /// D-15: the server hands back its own cursor as
    /// `datetime.now(timezone.utc).isoformat()`, which always ends in a
    /// literal `+00:00` UTC offset - every poll after the first therefore
    /// exercises this. `URLQueryItem` leaves `+` unescaped (legal in a query
    /// per RFC 3986), but the server decodes query strings the
    /// x-www-form-urlencoded way, where `+` means space; an unescaped cursor
    /// silently became `...079047 00:00` server-side and failed ISO-8601
    /// parsing with 400 on every incremental sync after the first (found via
    /// a real two-machine pairing test: the app permanently showed "possible
    /// once connected to the Mac mini" because every poll after startup
    /// failed this way). Runs against the real `damso.server.main` process,
    /// not a mock, since the bug is specifically about how Python's own
    /// query decoder reads the wire bytes.
    @Test
    func changesCursorWithAUTCOffsetSurvivesARoundTripThroughTheRealServer() async throws {
        let server = try LiveDamsoServerProcess.start(host: "0.0.0.0")
        defer { server.stop() }
        let credentials = try #require(server.credentials)

        let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        try configuration.configureRemote(host: "127.0.0.1", port: server.port, token: credentials.token, storeRootPath: server.storeRoot.path)
        let client = DamsoHTTPClient(configuration: configuration)

        let cursorWithUTCOffset = "2026-08-10T12:58:00.079047+00:00"
        let data = try await Task.detached(priority: .userInitiated) {
            try client.changes(since: cursorWithUTCOffset)
        }.value
        let envelope = try JSONDecoder().decode(ChangesResponse.self, from: data)
        #expect(!envelope.cursor.isEmpty)
    }

    /// Queue completion and incremental cache sync are independent requests.
    /// A real remote summary finished on the server while the client cache was
    /// still missing `summary.json`; the status poll decoded the missing file
    /// immediately and persisted `summary_artifact_invalid`, even though the
    /// periodic sync downloaded a valid result about a second later. The
    /// completion path now pulls its own artifact before the controller reads
    /// it, without waiting for the changelist cursor to catch up.
    @Test
    func completedRemoteSummaryIsPulledIntoTheCacheBeforeItIsDecoded() async throws {
        let server = try LiveDamsoServerProcess.start(host: "0.0.0.0")
        defer { server.stop() }
        let credentials = try #require(server.credentials)

        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("cache", isDirectory: true)
        let outboxRoot = base.appendingPathComponent("outbox", isDirectory: true)
        let stem = "summary-cache-race"

        let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        try configuration.configureRemote(host: "127.0.0.1", port: server.port, token: credentials.token, storeRootPath: server.storeRoot.path)
        let store = RemoteMeetingStore(
            client: DamsoHTTPClient(configuration: configuration),
            connectionConfiguration: configuration,
            cacheRoot: cacheRoot,
            outboxRoot: outboxRoot,
            needsCacheSync: true
        )

        let cache = MeetingStore(root: cacheRoot, minimumFreeBytes: 0)
        let cachedRecord = try cache.createRecord(MeetingDraft(stem: stem, source: .local, title: "Pending summary"))
        try cache.commit(cachedRecord)
        #expect(try store.storedSummaryArtifact(stem: stem) == nil)

        let serverDirectory = server.storeRoot.appendingPathComponent("Plaud/recordings/\(stem)", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
        try Data("""
        {"title":"Ready","role_hint":"","topic_summary":"Topic","one_line_summary":"Done","key_points":["Point"],"action_items":[],"person_notes":[]}
        """.utf8).write(to: serverDirectory.appendingPathComponent("summary.json"))

        #expect(await store.prepareCompletedArtifacts(stem: stem, kind: "summary"))
        let artifact = try #require(try store.storedSummaryArtifact(stem: stem))
        #expect(artifact.agentTitle == "Ready")
        #expect(artifact.summary.oneLine == "Done")
    }

    /// The incremental sync (D-15) carries no deletion tombstones, so a
    /// remote delete must purge this Mac's cache and outbox mirrors itself -
    /// and the server side must treat deleting an already-gone recording as
    /// success. A real two-machine run hit the combination: a server-side
    /// delete succeeded, the local copies stayed and resurrected the meeting
    /// in the UI, and every retry then failed against the missing server
    /// directory, leaving the meeting permanently undeletable.
    @Test
    func deletingARemoteRecordPurgesTheLocalMirrorsAndRetriesAreIdempotent() async throws {
        let server = try LiveDamsoServerProcess.start(host: "0.0.0.0")
        defer { server.stop() }
        let credentials = try #require(server.credentials)

        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("cache", isDirectory: true)
        let outboxRoot = base.appendingPathComponent("outbox", isDirectory: true)

        let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        try configuration.configureRemote(host: "127.0.0.1", port: server.port, token: credentials.token, storeRootPath: server.storeRoot.path)
        let store = RemoteMeetingStore(client: DamsoHTTPClient(configuration: configuration), connectionConfiguration: configuration, cacheRoot: cacheRoot, outboxRoot: outboxRoot, needsCacheSync: true)

        // The steady state after a handoff: the record lives on the server,
        // with a metadata mirror in the cache and leftover outbox debris.
        let stem = "local-delete-fixture"
        let cache = MeetingStore(root: cacheRoot, minimumFreeBytes: 0)
        let record = try cache.createRecord(MeetingDraft(stem: stem, source: .local, title: "To delete"))
        try cache.commit(record)
        let outbox = MeetingStore(root: outboxRoot, minimumFreeBytes: 0)
        try outbox.commit(record)
        let serverDirectory = server.storeRoot.appendingPathComponent("Plaud/recordings/\(stem)", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
        let cacheMeetingJSON = cacheRoot.appendingPathComponent("Plaud/recordings/\(stem)/meeting.json")
        try FileManager.default.copyItem(at: cacheMeetingJSON, to: serverDirectory.appendingPathComponent("meeting.json"))

        try await Task.detached(priority: .userInitiated) {
            try store.delete(stem: stem)
        }.value
        #expect(!FileManager.default.fileExists(atPath: serverDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("Plaud/recordings/\(stem)").path))
        #expect(!FileManager.default.fileExists(atPath: outboxRoot.appendingPathComponent("Plaud/recordings/\(stem)").path))

        // The lagging-mirror retry: the server directory is already gone but
        // a cache copy reappears (e.g. an interrupted earlier attempt).
        // Deleting again must succeed and clear it instead of erroring.
        let resurrected = try cache.createRecord(MeetingDraft(stem: stem, source: .local, title: "Stale copy"))
        try cache.commit(resurrected)
        try await Task.detached(priority: .userInitiated) {
            try store.delete(stem: stem)
        }.value
        #expect(!FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("Plaud/recordings/\(stem)").path))
    }

    /// `RemoteConnectivityTracker` (R9b) only ever updates as a side effect
    /// of other real traffic - `probeReachability` is the one method that
    /// asks directly, cheaply and without auth, so the connection-status
    /// poll timer can self-heal a stale "disconnected" verdict on its own
    /// instead of waiting for incidental traffic that might never come
    /// (confirmed live: the paired mini answered a direct probe in ~50ms
    /// while the app's own status still read "disconnected" from an old
    /// failure). Real server up vs. a host that refuses the connection -
    /// exactly the two cases the poll timer distinguishes.
    @Test
    func probeReachabilityReflectsWhetherTheRealServerAnswers() async throws {
        let server = try LiveDamsoServerProcess.start(host: "0.0.0.0")
        defer { server.stop() }
        let credentials = try #require(server.credentials)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let reachable = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        try reachable.configureRemote(host: "127.0.0.1", port: server.port, token: credentials.token, storeRootPath: server.storeRoot.path)
        let reachableStore = RemoteMeetingStore(
            client: DamsoHTTPClient(configuration: reachable),
            connectionConfiguration: reachable,
            cacheRoot: base.appendingPathComponent("cache-a", isDirectory: true),
            outboxRoot: base.appendingPathComponent("outbox-a", isDirectory: true),
            needsCacheSync: true
        )
        #expect(await reachableStore.probeReachability())

        let unreachable = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        try unreachable.configureRemote(host: "127.0.0.1", port: 1, token: "irrelevant", storeRootPath: "/tmp")
        let unreachableStore = RemoteMeetingStore(
            client: DamsoHTTPClient(configuration: unreachable),
            connectionConfiguration: unreachable,
            cacheRoot: base.appendingPathComponent("cache-b", isDirectory: true),
            outboxRoot: base.appendingPathComponent("outbox-b", isDirectory: true),
            needsCacheSync: true
        )
        #expect(await unreachableStore.probeReachability() == false)
    }

    /// Recluster needs the actual audio bytes, not just a playback URL - and
    /// unlike the audio player, it never triggered the on-demand fetch (R7
    /// excludes audio from the periodic cache sync). Pressing "Re-split
    /// speakers" on a meeting whose audio had never been fetched (e.g. it
    /// was never played) silently did nothing at all - no error, no request.
    /// This proves the fix over a real download from a real server.
    ///
    /// The RPC's `audio_path`, separately, must resolve on the *server*, not
    /// the client: the backend runs wherever `DamsoHTTPClient` points (a
    /// real paired Mac mini in remote mode, not this test process), and its
    /// `canonical_audio_path` requires the file to sit directly inside
    /// `recording_directory` on its own filesystem. Sending the client's
    /// local cache path there is a foreign, nonexistent path on a real
    /// two-machine setup - confirmed against the actual paired mini, whose
    /// `canonical_audio_path` rejected it in ~50ms with
    /// `invalid_local_processing_request`, indistinguishable from any other
    /// failure once it reached this call's generic `.failure` branch. This
    /// test's `cacheRoot` and `server.storeRoot` are already two distinct
    /// directories, so asserting against `serverDirectory` here is what
    /// actually exercises that mismatch instead of masking it.
    @Test @MainActor
    func reclusterFetchesMissingAudioOnDemandBeforeRunning() async throws {
        let server = try LiveDamsoServerProcess.start(host: "0.0.0.0")
        defer { server.stop() }
        let credentials = try #require(server.credentials)

        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let cacheRoot = base.appendingPathComponent("cache", isDirectory: true)
        let outboxRoot = base.appendingPathComponent("outbox", isDirectory: true)

        let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
        try configuration.configureRemote(host: "127.0.0.1", port: server.port, token: credentials.token, storeRootPath: server.storeRoot.path)
        let client = DamsoHTTPClient(configuration: configuration)
        let store = RemoteMeetingStore(client: client, connectionConfiguration: configuration, cacheRoot: cacheRoot, outboxRoot: outboxRoot, needsCacheSync: true)

        // The cache has the record (as a real remote store would after
        // sync), but never the audio - only the server has it.
        let stem = "recluster-fixture"
        let cache = MeetingStore(root: cacheRoot, minimumFreeBytes: 0)
        var record = try cache.createRecord(MeetingDraft(stem: stem, source: .local, title: "Fixture"))
        record.stage = .speakerReview
        record.originalAudioFile = "microphone.caf"
        try cache.commit(record)
        let serverDirectory = server.storeRoot.appendingPathComponent("Plaud/recordings/\(stem)", isDirectory: true)
        try FileManager.default.createDirectory(at: serverDirectory, withIntermediateDirectories: true)
        try Data("synthetic audio only on the server".utf8).write(to: serverDirectory.appendingPathComponent("microphone.caf"))

        let backend = RecordingFakeBackend()
        let controller = MeetingWorkspaceController(store: store, capture: NoopLiveCapture(), backend: backend, audioFetcher: RemoteAudioFetcher(client: client, tracker: RemoteConnectivityTracker()))
        controller.refreshLibrary()
        controller.select(stem: stem)

        await controller.reclusterSpeakers(count: 2)

        #expect(backend.reclusterRequests.count == 1)
        // The bytes still land in the local cache (needed to confirm the
        // file is actually fetchable and to pick a filename), but the
        // request itself must point at the server's own copy.
        let localAudioURL = cacheRoot.appendingPathComponent("Plaud/recordings/\(stem)/microphone.caf")
        #expect(FileManager.default.fileExists(atPath: localAudioURL.path))
        let serverAudioURL = serverDirectory.appendingPathComponent("microphone.caf")
        #expect(backend.reclusterRequests.first?.audioPath == serverAudioURL.path)
        #expect(controller.recoveryAction == nil)
    }
}

@MainActor
private final class NoopLiveCapture: RecordingCapture {
    func permissionState() async -> RecordingPermissionState { .ready }
    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles { fatalError("unused") }
    func stop() async throws -> CapturedAudioFiles { fatalError("unused") }
}

/// Records only the recluster call actually under test; every other
/// `LocalProcessingBackend` method is unused by this scenario.
private final class RecordingFakeBackend: LocalProcessingBackend, @unchecked Sendable {
    private let lock = NSLock()
    var reclusterRequests: [LocalReclusterRequest] = []

    func recluster(_ request: LocalReclusterRequest) throws -> LocalProcessingResult {
        lock.lock()
        defer { lock.unlock() }
        reclusterRequests.append(request)
        return LocalProcessingResult(ok: true, stage: "speaker_review", speakerCount: request.numSpeakers)
    }

    // `select(stem:)` fires several of these in unawaited background Tasks
    // as side effects (candidate refresh, speaker suggestions, transcript
    // cleanup) - they are incidental to this scenario, not under test, but
    // still need a safe response rather than a crash if they happen to run.
    func applyResolutions(_ request: LocalResolutionProcessingRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func appendPersonNote(_ request: LocalPersonNoteRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func refreshCandidates(_ request: LocalRefreshCandidatesRequest) throws -> LocalProcessingResult {
        LocalProcessingResult(ok: true, stage: "candidates_refreshed", speakerCount: nil)
    }
    func setPersonEmail(_ request: LocalPersonEmailRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func removePersonAlias(_ request: LocalRemovePersonAliasRequest) throws -> LocalProcessingResult { fatalError("unused") }
    func suggestSpeakers(_ request: LocalSpeakerHintsRequest) throws -> LocalSpeakerHintsResult {
        LocalSpeakerHintsResult(ok: true, status: "complete", errorCode: nil, suggestions: [])
    }
    func cleanTranscript(_ request: LocalTranscriptCleanupRequest) throws -> LocalTranscriptCleanupResult {
        LocalTranscriptCleanupResult(ok: true, status: "complete", errorCode: nil, correctionCount: 0)
    }
    func rebuildIndex(storeRoot: String) throws -> LocalIndexResult { LocalIndexResult(ok: true, meetings: 0) }
}
