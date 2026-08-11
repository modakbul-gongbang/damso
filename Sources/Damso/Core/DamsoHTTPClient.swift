import Foundation

/// Must track `backend/damso/serve.py`'s `PROTOCOL_VERSION` exactly - the
/// only contract that keeps a mismatched server/client pair from silently
/// disagreeing about a request's shape. Sent as a header now (D-16:
/// `X-Damso-Protocol-Version`) rather than injected into the JSON body,
/// since several endpoints (`/v1/changes`, file GET, upload) have no body
/// shaped like the old ssh-era RPC envelope to inject a field into.
enum DamsoServerProtocol {
    static let version = 1
    static let versionHeader = "X-Damso-Protocol-Version"
}

enum DamsoServerError: Error, Equatable {
    case requestEncoding
    case transportFailed
    case remoteMisconfigured
    case unauthorized
    /// The server rejected `X-Damso-Protocol-Version` (409) - surfaced as one
    /// message: update Damso on the server.
    case remoteUpdateRequired
    case notFound
    case conflict
    case payloadTooLarge
    case unprocessable(detail: String)
    /// A known operation that failed inside its own Python logic; mirrors
    /// `damso.processing`'s error envelope exactly (unchanged from the
    /// ssh-era `.backend` case).
    case backend(code: String, nextAction: String)
    case invalidResponse
}

/// The one client for talking to the Damso HTTP daemon (R1, R2, D-06):
/// resolves the base URL and auth from `ServerConnectionConfiguration`,
/// attaches the protocol-version header and (remote-only) the bearer token,
/// and unwraps the ok/error envelope shape `/v1/rpc` and the extra operations
/// share. Every transport call updates `RemoteConnectivityTracker` as a side
/// effect (R9b - never a dedicated health-check ping of its own), exactly
/// like the ssh-era `DamsoServeClient`.
struct DamsoHTTPClient {
    let configuration: ServerConnectionConfiguration
    let tracker: RemoteConnectivityTracker

    init(configuration: ServerConnectionConfiguration = ServerConnectionConfiguration(), tracker: RemoteConnectivityTracker = .shared) {
        self.configuration = configuration
        self.tracker = tracker
    }

    /// Plain HTTP in both modes (ADR 0003), so one shared session covers
    /// them; there is no per-connection trust decision left to make.
    private var session: URLSession { .shared }

    /// 15s, not URLSession's 60s default: a genuinely unreachable server (a
    /// bad host, a sleeping Mac, no network) must fail fast enough for
    /// `guardRemoteWrite`-style UI feedback to feel like a response rather
    /// than a hang. Uploads use their own longer timeout below - a real
    /// meeting recording legitimately takes longer than 15s to transfer.
    private static let defaultTimeout: TimeInterval = 15

    private func authorizedRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: Self.defaultTimeout)
        request.httpMethod = method
        request.setValue(String(DamsoServerProtocol.version), forHTTPHeaderField: DamsoServerProtocol.versionHeader)
        if case .remote(_, _, let token) = configuration.mode {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: RPC (recluster, apply-resolutions, person ops, speaker-hints, transcript-cleanup, rebuild-index, commit-record, requeue triggers via /v1/rpc)

    /// Encodes `request` as JSON, POSTs it to `/v1/rpc`, and returns the raw
    /// response bytes after rejecting a protocol/transport-level error.
    /// Callers decode the remaining ok/error envelope with `DamsoHTTPClient.decode`.
    func send(_ request: some Encodable) throws -> Data {
        let body: Data
        do {
            let encoder = JSONEncoder()
            DateCoding.configure(encoder)
            body = try encoder.encode(request)
        } catch {
            throw DamsoServerError.requestEncoding
        }
        var urlRequest = authorizedRequest(url: configuration.baseURL.appendingPathComponent("v1/rpc"), method: "POST")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = body
        return try performSynchronously(urlRequest)
    }

    // MARK: Changes, files, status, requeue, summary trigger

    func changes(since cursor: String?) throws -> Data {
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent("v1/changes"), resolvingAgainstBaseURL: false)
        if let cursor {
            // `URLQueryItem` leaves `+` unencoded (it is a legal, unreserved
            // query character per RFC 3986), but the server's query-string
            // decoder treats `+` as an encoded space (the
            // application/x-www-form-urlencoded convention) - so a UTC
            // offset cursor like `...079047+00:00` silently became
            // `...079047 00:00` server-side and failed ISO-8601 parsing with
            // 400 Bad Request on every sync poll after the first one.
            // `percentEncodedQueryItems` bypasses `URLQueryItem`'s own
            // encoding, so `+` has to be escaped by hand here.
            var allowedCharacters = CharacterSet.urlQueryAllowed
            allowedCharacters.remove("+")
            let encodedCursor = cursor.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? cursor
            components?.percentEncodedQueryItems = [URLQueryItem(name: "since", value: encodedCursor)]
        }
        let request = authorizedRequest(url: components?.url ?? configuration.baseURL.appendingPathComponent("v1/changes"), method: "GET")
        return try performSynchronously(request)
    }

    func downloadFile(stem: String, filename: String, to destination: URL) throws {
        let url = configuration.baseURL.appendingPathComponent("v1/recordings/\(stem)/files/\(filename)")
        let request = authorizedRequest(url: url, method: "GET")
        let data = try performSynchronously(request)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
    }

    func status(stem: String) throws -> Data {
        let url = configuration.baseURL.appendingPathComponent("v1/recordings/\(stem)/status")
        return try performSynchronously(authorizedRequest(url: url, method: "GET"))
    }

    func requeue(stem: String) throws -> Data {
        let url = configuration.baseURL.appendingPathComponent("v1/recordings/\(stem)/requeue")
        return try performSynchronously(authorizedRequest(url: url, method: "POST"))
    }

    func triggerSummary(stem: String, agent: String, language: String, meetingDate: String?) throws -> Data {
        let url = configuration.baseURL.appendingPathComponent("v1/recordings/\(stem)/summary")
        var request = authorizedRequest(url: url, method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: String?] = ["agent": agent, "language": language, "meeting_date": meetingDate]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 })
        return try performSynchronously(request)
    }

    /// Uploads a tar.gz archive of one outbox record (D-23: whole-file
    /// retry, no chunking). Returns the raw `{"ok": true, "recording_stem":
    /// ...}` body.
    func uploadRecording(archiveData: Data) throws -> Data {
        var request = authorizedRequest(url: configuration.baseURL.appendingPathComponent("v1/recordings"), method: "POST")
        // A real meeting recording legitimately takes longer than the
        // default RPC timeout to transfer, especially over a slow LAN link.
        request.timeoutInterval = 600
        request.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
        request.httpBody = archiveData
        return try performSynchronously(request)
    }

    // MARK: Pairing preflight (no auth required for health/version)

    struct VersionInfo: Decodable {
        let protocolVersion: Int
        let serverVersion: String
    }

    /// Used during pairing to confirm a Damso daemon is actually there and
    /// speaks a protocol version this client understands, before the one
    /// authenticated preflight call below.
    static func probeVersion(host: String, port: Int) throws -> VersionInfo {
        let url = URL(string: "http://\(host):\(port)/v1/version")!
        let request = URLRequest(url: url, timeoutInterval: 10)
        let (data, response) = try performSynchronously(session: .shared, request: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DamsoServerError.transportFailed
        }
        let decoder = JSONDecoder()
        guard let info = try? decoder.decode(VersionInfo.self, from: data) else {
            throw DamsoServerError.invalidResponse
        }
        return info
    }

    enum AuthorizedAccessResult: Equatable {
        /// Carries the daemon's real canonical store root - every
        /// record-mutation RPC (`delete-record`, `update-record`,
        /// `quarantine-record`, ...) builds its `recording_directory` from
        /// this path, so pairing must capture the real value here rather
        /// than leaving it empty; an empty root silently breaks every one
        /// of those calls in remote mode (confirmed: a client paired
        /// without ever fixing this could not delete or mutate any record
        /// it had already synced down).
        case authorized(storeRootPath: String)
        case unauthorized
    }

    /// AC2's "잘못된 토큰은 401 안내": health/version stay unauthenticated
    /// (D-08), so they alone can never tell a wrong token from a right one.
    /// This is the one preflight call the pairing Check step makes against an
    /// authenticated endpoint. `.unauthorized` means the server answered 401,
    /// and any other outcome (unreachable, wrong shape) throws like the rest
    /// of this client's transport calls.
    static func probeAuthorizedAccess(host: String, port: Int, token: String) throws -> AuthorizedAccessResult {
        let url = URL(string: "http://\(host):\(port)/v1/changes")!
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(String(DamsoServerProtocol.version), forHTTPHeaderField: DamsoServerProtocol.versionHeader)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try performSynchronously(session: .shared, request: request)
        guard let http = response as? HTTPURLResponse else { throw DamsoServerError.transportFailed }
        switch http.statusCode {
        case 200:
            struct Envelope: Decodable { let storeRootPath: String }
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                throw DamsoServerError.invalidResponse
            }
            return .authorized(storeRootPath: envelope.storeRootPath)
        case 401:
            return .unauthorized
        default:
            throw DamsoServerError.transportFailed
        }
    }

    // MARK: Transport

    private func performSynchronously(_ request: URLRequest) throws -> Data {
        let (data, response) = try Self.performSynchronously(session: session, request: request)
        return try process(data: data, response: response)
    }

    private func process(data: Data, response: URLResponse) throws -> Data {
        guard let http = response as? HTTPURLResponse else {
            tracker.noteFailure(.transportFailed)
            throw DamsoServerError.transportFailed
        }
        switch http.statusCode {
        case 200..<300:
            tracker.noteSuccess()
            return data
        case 401:
            tracker.noteFailure(.unauthorized)
            throw DamsoServerError.unauthorized
        case 404:
            tracker.noteSuccess()
            throw DamsoServerError.notFound
        case 409:
            tracker.noteFailure(.remoteUpdateRequired)
            throw DamsoServerError.remoteUpdateRequired
        case 413:
            tracker.noteSuccess()
            throw DamsoServerError.payloadTooLarge
        case 422:
            tracker.noteSuccess()
            let detail = (try? JSONDecoder().decode(DetailEnvelope.self, from: data))?.detail ?? "unprocessable"
            throw DamsoServerError.unprocessable(detail: detail)
        default:
            tracker.noteFailure(.transportFailed)
            throw DamsoServerError.transportFailed
        }
    }

    private struct DetailEnvelope: Decodable {
        let detail: String
    }

    /// A blocking wrapper around `URLSession`'s async data task: every
    /// existing call site (`LocalProcessingProcessRunner` and friends) is a
    /// synchronous `throws` function invoked from inside `Task.detached`, the
    /// same shape the ssh-era `Process`-spawning transport had. Blocking a
    /// background-priority detached task on a semaphore here is the smallest
    /// change that preserves every caller; a full async rewrite of the
    /// `LocalProcessingBackend` protocol is a larger, separate change.
    private static func performSynchronously(session: URLSession, request: URLRequest) throws -> (Data, URLResponse) {
        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Result<(Data, URLResponse), Error> = .failure(DamsoServerError.transportFailed)
            func set(_ newValue: Result<(Data, URLResponse), Error>) {
                lock.lock(); value = newValue; lock.unlock()
            }
            func get() -> Result<(Data, URLResponse), Error> {
                lock.lock(); defer { lock.unlock() }; return value
            }
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                box.set(.failure(error))
            } else if let data, let response {
                box.set(.success((data, response)))
            } else {
                box.set(.failure(DamsoServerError.transportFailed))
            }
            semaphore.signal()
        }
        task.resume()
        // A hard backstop independent of `request.timeoutInterval`: a
        // completion handler that never fires (a stalled DNS/connect phase
        // under some network sandboxes) would otherwise block this thread
        // forever regardless of the request-level timeout, which only bounds
        // the phases URLSession itself instruments. 10s of slack above the
        // request's own timeout is enough for URLSession's own timeout
        // machinery to win the race in the normal case; this only fires as a
        // last resort when it doesn't.
        let deadline = DispatchTime.now() + request.timeoutInterval + 10
        if semaphore.wait(timeout: deadline) == .timedOut {
            task.cancel()
            throw DamsoServerError.transportFailed
        }
        switch box.get() {
        case .success(let value):
            return value
        case .failure:
            throw DamsoServerError.transportFailed
        }
    }

    // MARK: Envelope decoding (unchanged shape from the ssh-era DamsoServeClient)

    private struct BackendErrorEnvelope: Decodable {
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

    static func decode<Response: Decodable>(_ data: Data, as type: Response.Type) throws -> Response {
        if let envelope = try? JSONDecoder().decode(BackendErrorEnvelope.self, from: data), !envelope.ok {
            throw DamsoServerError.backend(code: envelope.error.code, nextAction: envelope.error.nextAction)
        }
        let decoder = JSONDecoder()
        DateCoding.configure(decoder)
        guard let result = try? decoder.decode(Response.self, from: data) else {
            throw DamsoServerError.invalidResponse
        }
        return result
    }
}
