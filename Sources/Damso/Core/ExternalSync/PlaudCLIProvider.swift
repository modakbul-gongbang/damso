import Foundation

// MARK: CLI subprocess boundary

struct CLICommandResult: Equatable, Sendable {
    let exitCode: Int32
    let stdout: String
}

enum CLICommandError: Error, Equatable {
    case timedOut
    case launchFailed(String)
}

protocol CLICommandRunning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> CLICommandResult
}

/// Runs one CLI command with a hard wall-clock timeout. Stdout is captured to
/// a private temporary file (pipes deadlock on large output) and capped; a
/// timed-out process is terminated, then killed.
final class SubprocessCLIRunner: CLICommandRunning {
    static let outputLimitBytes = 8 * 1_024 * 1_024

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> CLICommandResult {
        try await Task.detached(priority: .utility) {
            try Self.runBlocking(executable: executable, arguments: arguments, environment: environment, timeout: timeout)
        }.value
    }

    private static func runBlocking(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> CLICommandResult {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("damso-cli-\(UUID().uuidString).out")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw CLICommandError.launchFailed(error.localizedDescription)
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 5)
            }
            throw CLICommandError.timedOut
        }

        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        guard data.count <= outputLimitBytes else { throw CLICommandError.launchFailed("output_limit_exceeded") }
        return CLICommandResult(exitCode: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self))
    }
}

// MARK: Audio download boundary

protocol AudioFileDownloading: Sendable {
    func download(from url: URL, to destination: URL, timeout: TimeInterval) async throws
}

struct URLSessionAudioDownloader: AudioFileDownloading {
    func download(from url: URL, to destination: URL, timeout: TimeInterval) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (temporary, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw ExternalSyncProviderError.transientFailure("audio_download_http_\(http.statusCode)")
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

// MARK: Plaud CLI provider

struct PlaudCLIConfiguration: Sendable {
    /// Fetch timeouts follow D-24: listing/metadata 60s, login 120s; the
    /// audio byte download uses the standard URLSession timeout capped at
    /// 10 minutes.
    var listTimeout: TimeInterval = 60
    var downloadTimeout: TimeInterval = 10 * 60
    var loginTimeout: TimeInterval = 2 * 60
    var pageSize = 100
    var maxPages = 50
}

/// First `ExternalSyncProvider`: the official `@plaud-ai/cli` subprocess.
/// Credentials live entirely in the CLI's own token store (`~/.plaud/`); the
/// app never sees, stores, or logs them. Exit code 2 is the CLI's documented
/// auth-failure signal and maps to `needsLogin`; any other non-zero exit,
/// timeout, or unparseable output maps to `transientFailure` (R4, D-21).
final class PlaudCLIProvider: ExternalSyncProvider {
    let id = "plaud"
    let displayName = "Plaud"
    static let installGuidanceCommand = "npm install -g @plaud-ai/cli"

    private let runner: any CLICommandRunning
    private let downloader: any AudioFileDownloading
    private let configuration: PlaudCLIConfiguration
    private let locateExecutable: @Sendable () -> URL?

    init(
        runner: any CLICommandRunning = SubprocessCLIRunner(),
        downloader: any AudioFileDownloading = URLSessionAudioDownloader(),
        configuration: PlaudCLIConfiguration = PlaudCLIConfiguration(),
        locateExecutable: @escaping @Sendable () -> URL? = { PlaudCLIProvider.locateInstalledCLI() }
    ) {
        self.runner = runner
        self.downloader = downloader
        self.configuration = configuration
        self.locateExecutable = locateExecutable
    }

    // MARK: Executable discovery

    /// Searches the deterministic runtime PATH plus nvm-managed Node
    /// installations, which a Finder-launched app never inherits.
    static func locateInstalledCLI(fileManager: FileManager = .default) -> URL? {
        var directories = (ProcessRuntime.environment()["PATH"] ?? "").split(separator: ":").map(String.init)
        let nvmVersions = ("\(NSHomeDirectory())/.nvm/versions/node" as NSString).expandingTildeInPath
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmVersions) {
            for version in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                directories.append("\(nvmVersions)/\(version)/bin")
            }
        }
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("plaud")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func subprocessEnvironment(for executable: URL) -> [String: String] {
        // The CLI is a Node script; prepend its own bin directory so the
        // matching node binary resolves even for nvm installs.
        var environment = ProcessRuntime.environment()
        let binDirectory = executable.deletingLastPathComponent().path
        environment["PATH"] = "\(binDirectory):\(environment["PATH"] ?? "")"
        return environment
    }

    // MARK: ExternalSyncProvider

    func accountState() async -> ExternalSyncAccountState {
        guard let executable = locateExecutable() else {
            return .notInstalled(guidance: Self.installGuidanceCommand)
        }
        do {
            let result = try await runner.run(
                executable: executable,
                arguments: ["me"],
                environment: subprocessEnvironment(for: executable),
                timeout: configuration.listTimeout
            )
            switch result.exitCode {
            case 0: return .connected
            case 2: return .needsLogin
            case 127: return .notInstalled(guidance: Self.installGuidanceCommand)
            default: return .error("plaud_cli_exit_\(result.exitCode)")
            }
        } catch CLICommandError.timedOut {
            return .error("plaud_cli_timeout")
        } catch {
            return .error("plaud_cli_unavailable")
        }
    }

    func beginLogin() async throws {
        guard let executable = locateExecutable() else { throw ExternalSyncProviderError.notInstalled }
        let result: CLICommandResult
        do {
            result = try await runner.run(
                executable: executable,
                arguments: ["login"],
                environment: subprocessEnvironment(for: executable),
                timeout: configuration.loginTimeout
            )
        } catch CLICommandError.timedOut {
            throw ExternalSyncProviderError.transientFailure("login_timed_out")
        } catch {
            throw ExternalSyncProviderError.transientFailure("login_launch_failed")
        }
        guard result.exitCode == 0 else {
            throw ExternalSyncProviderError.transientFailure("login_exit_\(result.exitCode)")
        }
    }

    func logout() async throws {
        guard let executable = locateExecutable() else { throw ExternalSyncProviderError.notInstalled }
        let result = try await mapCLIErrors {
            try await self.runner.run(
                executable: executable,
                arguments: ["logout"],
                environment: self.subprocessEnvironment(for: executable),
                timeout: self.configuration.listTimeout
            )
        }
        guard result.exitCode == 0 else {
            throw ExternalSyncProviderError.transientFailure("logout_exit_\(result.exitCode)")
        }
    }

    func listRecordings(since: Date) async throws -> [ExternalRecording] {
        guard let executable = locateExecutable() else { throw ExternalSyncProviderError.notInstalled }
        let environment = subprocessEnvironment(for: executable)
        var recordings: [ExternalRecording] = []
        var page = 1
        pageLoop: while page <= configuration.maxPages {
            let result = try await mapCLIErrors {
                try await self.runner.run(
                    executable: executable,
                    arguments: ["files", "-p", String(page), "-s", String(self.configuration.pageSize)],
                    environment: environment,
                    timeout: self.configuration.listTimeout
                )
            }
            try Self.requireSuccess(result, context: "list")
            let rows = Self.parseFilesTable(result.stdout)
            guard !rows.isEmpty else { break }
            for row in rows {
                guard let rowDay = Self.parseListDate(row.dateText) else { continue }
                // Rows are newest first; a whole day older than the window
                // means every later row is older too.
                let endOfRowDay = rowDay.addingTimeInterval(24 * 60 * 60)
                if endOfRowDay < since { break pageLoop }
                guard Self.isSafeRemoteID(row.id) else { continue }
                let recording = try await fetchRecordingDetails(
                    id: row.id,
                    fallbackTitle: row.name,
                    fallbackStart: rowDay,
                    executable: executable,
                    environment: environment
                )
                if recording.startedAt >= since {
                    recordings.append(recording)
                }
            }
            if rows.count < configuration.pageSize { break }
            page += 1
        }
        return recordings
    }

    func downloadAudio(remoteID: String, into directory: URL) async throws -> URL {
        guard let executable = locateExecutable() else { throw ExternalSyncProviderError.notInstalled }
        guard Self.isSafeRemoteID(remoteID) else { throw ExternalSyncProviderError.transientFailure("unsafe_remote_id") }
        let result = try await mapCLIErrors {
            try await self.runner.run(
                executable: executable,
                arguments: ["audio", remoteID],
                environment: self.subprocessEnvironment(for: executable),
                timeout: self.configuration.listTimeout
            )
        }
        try Self.requireSuccess(result, context: "audio")
        guard let url = Self.parseAudioURL(result.stdout) else {
            throw ExternalSyncProviderError.transientFailure("audio_url_missing")
        }
        let fileExtension = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        let destination = directory.appendingPathComponent("recording.\(fileExtension)")
        do {
            try await downloader.download(from: url, to: destination, timeout: configuration.downloadTimeout)
        } catch let error as ExternalSyncProviderError {
            throw error
        } catch {
            throw ExternalSyncProviderError.transientFailure("audio_download_failed")
        }
        return destination
    }

    private func fetchRecordingDetails(
        id: String,
        fallbackTitle: String,
        fallbackStart: Date,
        executable: URL,
        environment: [String: String]
    ) async throws -> ExternalRecording {
        let result = try await mapCLIErrors {
            try await self.runner.run(
                executable: executable,
                arguments: ["file", id],
                environment: environment,
                timeout: self.configuration.listTimeout
            )
        }
        try Self.requireSuccess(result, context: "detail")
        let details = Self.parseFileDetails(result.stdout)
        let startedAt = details["start_at"].flatMap(Self.parseTimestamp)
            ?? details["created_at"].flatMap(Self.parseTimestamp)
            ?? fallbackStart
        let name = details["name"].flatMap { $0 == "-" ? nil : $0 } ?? fallbackTitle
        return ExternalRecording(
            remoteID: id,
            title: name.isEmpty ? nil : name,
            startedAt: startedAt,
            duration: nil
        )
    }

    private func mapCLIErrors(_ operation: () async throws -> CLICommandResult) async throws -> CLICommandResult {
        do {
            return try await operation()
        } catch CLICommandError.timedOut {
            throw ExternalSyncProviderError.transientFailure("cli_timeout")
        } catch let error as ExternalSyncProviderError {
            throw error
        } catch {
            throw ExternalSyncProviderError.transientFailure("cli_launch_failed")
        }
    }

    private static func requireSuccess(_ result: CLICommandResult, context: String) throws {
        switch result.exitCode {
        case 0: return
        case 2: throw ExternalSyncProviderError.needsLogin
        default: throw ExternalSyncProviderError.transientFailure("\(context)_exit_\(result.exitCode)")
        }
    }

    // MARK: Output parsing (verified against @plaud-ai/cli 0.3.x)

    struct FileListRow: Equatable {
        let id: String
        let name: String
        let dateText: String
    }

    /// `plaud files` prints a fixed-width table: two leading spaces, then
    /// id.padEnd(34), two spaces, name pad/truncate(36), two spaces,
    /// date "YYYY-MM-DD".padEnd(12), two spaces, duration.
    static func parseFilesTable(_ stdout: String) -> [FileListRow] {
        var rows: [FileListRow] = []
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            if let row = parseFixedWidthRow(String(line)) ?? parseLooseRow(String(line)) {
                rows.append(row)
            }
        }
        return rows
    }

    private static func parseFixedWidthRow(_ line: String) -> FileListRow? {
        guard line.count >= 88, line.hasPrefix("  ") else { return nil }
        let characters = Array(line)
        let id = String(characters[2..<36]).trimmingCharacters(in: .whitespaces)
        let name = String(characters[38..<74]).trimmingCharacters(in: .whitespaces)
        let date = String(characters[76..<min(88, characters.count)]).trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, looksLikeListDate(date) else { return nil }
        return FileListRow(id: id, name: name, dateText: date)
    }

    /// Rescue path for an id longer than the fixed column: split on runs of
    /// two or more spaces and require the date column shape.
    private static func parseLooseRow(_ line: String) -> FileListRow? {
        guard line.hasPrefix("  ") else { return nil }
        let fields = line.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: "  ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard fields.count >= 4, looksLikeListDate(fields[fields.count - 2]) else { return nil }
        return FileListRow(
            id: fields[0],
            name: fields[1..<(fields.count - 2)].joined(separator: " "),
            dateText: fields[fields.count - 2]
        )
    }

    private static func looksLikeListDate(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    /// `plaud file <id>` prints `  key:  value` lines under "File Details:".
    static func parseFileDetails(_ stdout: String) -> [String: String] {
        var details: [String: String] = [:]
        for line in stdout.split(separator: "\n") {
            guard let match = String(line).range(of: #"^\s{2}([a-z_]+):\s+(.+?)\s*$"#, options: .regularExpression) else { continue }
            let text = String(String(line)[match])
            guard let colon = text.firstIndex(of: ":") else { continue }
            let key = text[..<colon].trimmingCharacters(in: .whitespaces)
            let value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if details[key] == nil { details[key] = value }
        }
        return details
    }

    /// `plaud audio <id>` prints the presigned URL on its own line.
    static func parseAudioURL(_ stdout: String) -> URL? {
        for line in stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
                return URL(string: trimmed)
            }
        }
        return nil
    }

    /// The CLI prints `created_at`/`start_at` raw from the API. Live-verified
    /// shape (2026-07-17): timezone-less ISO in UTC with optional fractional
    /// seconds, e.g. `2026-07-14T13:31:10.310000` (cross-checked against the
    /// epoch-ms `serial_number` of the same file). Also accept full ISO 8601
    /// and epoch milliseconds/seconds defensively.
    static func parseTimestamp(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "-" else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: value) { return date }
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        if let numeric = Double(value), numeric > 0 {
            if numeric > 1e12 { return Date(timeIntervalSince1970: numeric / 1_000) }
            if numeric > 1e9 { return Date(timeIntervalSince1970: numeric) }
        }
        return nil
    }

    static func parseListDate(_ raw: String, calendar: Calendar = .current) -> Date? {
        guard looksLikeListDate(raw) else { return nil }
        let parts = raw.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func isSafeRemoteID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.allSatisfy { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
        } && value != "." && value != ".."
    }
}
