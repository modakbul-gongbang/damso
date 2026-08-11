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
}
