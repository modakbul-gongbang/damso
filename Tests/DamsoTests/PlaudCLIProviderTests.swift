import Foundation
import Testing
@testable import Damso

// MARK: Fake CLI runner

private final class FakeCLIRunner: CLICommandRunning, @unchecked Sendable {
    enum Response {
        case result(CLICommandResult)
        case error(Error)
    }

    private let lock = NSLock()
    private var _calls: [[String]] = []
    /// Keyed by the subcommand ("files", "file", "audio", "me", ...); "files"
    /// responses pop in order so pagination can be scripted.
    private var filesQueue: [Response] = []
    private var byCommand: [String: Response] = [:]

    var calls: [[String]] { lock.withLock { _calls } }

    func queueFiles(_ responses: Response...) {
        lock.withLock { filesQueue.append(contentsOf: responses) }
    }

    func respond(to command: String, with response: Response) {
        lock.withLock { byCommand[command] = response }
    }

    func run(executable: URL, arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> CLICommandResult {
        let response: Response? = lock.withLock {
            _calls.append(arguments)
            guard let command = arguments.first else { return nil }
            if command == "files", !filesQueue.isEmpty {
                return filesQueue.removeFirst()
            }
            return byCommand[command]
        }
        switch response {
        case .result(let result): return result
        case .error(let error): throw error
        case nil: return CLICommandResult(exitCode: 1, stdout: "")
        }
    }
}

private func makeProvider(runner: FakeCLIRunner, pageSize: Int = 10) -> PlaudCLIProvider {
    var configuration = PlaudCLIConfiguration()
    configuration.pageSize = pageSize
    return PlaudCLIProvider(
        runner: runner,
        downloader: NoopDownloader(),
        configuration: configuration,
        locateExecutable: { URL(fileURLWithPath: "/usr/local/bin/plaud") }
    )
}

private struct NoopDownloader: AudioFileDownloading {
    func download(from url: URL, to destination: URL, timeout: TimeInterval) async throws {
        try Data("payload".utf8).write(to: destination)
    }
}

private func filesTableRow(id: String, name: String, date: String, duration: String = "5m30s") -> String {
    "  " + id.padding(toLength: 34, withPad: " ", startingAt: 0)
        + "  " + name.padding(toLength: 36, withPad: " ", startingAt: 0)
        + "  " + date.padding(toLength: 12, withPad: " ", startingAt: 0)
        + "  " + duration
}

private func filesTableOutput(rows: [String]) -> String {
    ([
        "",
        "Files on this page: \(rows.count)",
        "",
        "  " + "ID".padding(toLength: 34, withPad: " ", startingAt: 0)
            + "  " + "NAME".padding(toLength: 36, withPad: " ", startingAt: 0)
            + "  " + "DATE".padding(toLength: 12, withPad: " ", startingAt: 0)
            + "  DURATION",
        "  " + String(repeating: "─", count: 98),
    ] + rows).joined(separator: "\n")
}

private func fileDetailsOutput(id: String, name: String, createdAt: String, startAt: String) -> String {
    """

    File Details:

      id:           \(id)
      name:         \(name)
      created_at:   \(createdAt)
      start_at:     \(startAt)
      duration:     5m30s
      serial_number: PLD-1
      audio:        available
      transcript:   available
      summary:      unavailable

    """
}

// MARK: Output parsing (verified CLI table/detail/audio shapes)

@Test
func parsesTheFixedWidthFilesTableIncludingTruncatedNames() {
    let output = filesTableOutput(rows: [
        filesTableRow(id: "665f0a1b2c3d4e5f66778899aabbccdd", name: "회의 녹음 아주 긴 제목이 잘려서 나오는 경우…", date: "2026-07-16"),
        filesTableRow(id: "775f0a1b2c3d4e5f66778899aabbccdd", name: "Standup", date: "2026-07-15"),
    ])
    let rows = PlaudCLIProvider.parseFilesTable(output)
    #expect(rows.count == 2)
    #expect(rows[0].id == "665f0a1b2c3d4e5f66778899aabbccdd")
    #expect(rows[0].dateText == "2026-07-16")
    #expect(rows[1].name == "Standup")
}

@Test
func parsesFileDetailsKeyValueLines() {
    let details = PlaudCLIProvider.parseFileDetails(
        fileDetailsOutput(id: "abc123", name: "Weekly sync", createdAt: "2026-07-16T09:30:00.000Z", startAt: "1784269800000")
    )
    #expect(details["id"] == "abc123")
    #expect(details["name"] == "Weekly sync")
    #expect(details["created_at"] == "2026-07-16T09:30:00.000Z")
    #expect(details["start_at"] == "1784269800000")
}

@Test
func parsesTimestampsFromISOAndEpochFormats() {
    #expect(PlaudCLIProvider.parseTimestamp("2026-07-16T09:30:00Z") == Date(timeIntervalSince1970: 1_784_194_200))
    #expect(PlaudCLIProvider.parseTimestamp("2026-07-16T09:30:00.500Z") == Date(timeIntervalSince1970: 1_784_194_200.5))
    #expect(PlaudCLIProvider.parseTimestamp("1784194200000") == Date(timeIntervalSince1970: 1_784_194_200))
    #expect(PlaudCLIProvider.parseTimestamp("1784194200") == Date(timeIntervalSince1970: 1_784_194_200))
    // Live-verified CLI shape: timezone-less ISO in UTC, optional 6-digit
    // fractional seconds (cross-checked against the epoch-ms serial_number).
    #expect(PlaudCLIProvider.parseTimestamp("2026-07-14T13:31:10.310000") == Date(timeIntervalSince1970: 1_784_035_870.31))
    #expect(PlaudCLIProvider.parseTimestamp("2026-07-14T13:54:25") == Date(timeIntervalSince1970: 1_784_037_265))
    #expect(PlaudCLIProvider.parseTimestamp("-") == nil)
    #expect(PlaudCLIProvider.parseTimestamp("garbage") == nil)
}

@Test
func parsesTheAudioURLLine() {
    let output = """

    Audio Download URL:

    https://cdn.plaud.ai/audio/abc123.mp3?expires=1

    Note: This URL expires in 24 hours.

    """
    #expect(PlaudCLIProvider.parseAudioURL(output)?.absoluteString == "https://cdn.plaud.ai/audio/abc123.mp3?expires=1")
    #expect(PlaudCLIProvider.parseAudioURL("Audio not available for this recording.") == nil)
}

@Test
func rejectsUnsafeRemoteIDs() {
    #expect(PlaudCLIProvider.isSafeRemoteID("665f0a1b2c3d"))
    #expect(!PlaudCLIProvider.isSafeRemoteID("../escape"))
    #expect(!PlaudCLIProvider.isSafeRemoteID("a/b"))
    #expect(!PlaudCLIProvider.isSafeRemoteID(""))
}

// MARK: Exit code and timeout mapping (AC4, AC13)

@Test
func exitCodeTwoMapsToNeedsLoginEverywhere() async {
    let runner = FakeCLIRunner()
    runner.respond(to: "me", with: .result(CLICommandResult(exitCode: 2, stdout: "")))
    runner.queueFiles(.result(CLICommandResult(exitCode: 2, stdout: "")))
    let provider = makeProvider(runner: runner)

    #expect(await provider.accountState() == .needsLogin)
    await #expect(throws: ExternalSyncProviderError.needsLogin) {
        _ = try await provider.listRecordings(since: .distantPast)
    }
}

@Test
func timeoutsAndUnknownExitCodesMapToTransientFailure() async {
    let runner = FakeCLIRunner()
    runner.queueFiles(.error(CLICommandError.timedOut))
    runner.queueFiles(.result(CLICommandResult(exitCode: 3, stdout: "")))
    let provider = makeProvider(runner: runner)

    await #expect(throws: ExternalSyncProviderError.transientFailure("cli_timeout")) {
        _ = try await provider.listRecordings(since: .distantPast)
    }
    await #expect(throws: ExternalSyncProviderError.transientFailure("list_exit_3")) {
        _ = try await provider.listRecordings(since: .distantPast)
    }
}

@Test
func missingExecutableReportsNotInstalledWithInstallGuidance() async {
    let provider = PlaudCLIProvider(
        runner: FakeCLIRunner(),
        downloader: NoopDownloader(),
        locateExecutable: { nil }
    )
    #expect(await provider.accountState() == .notInstalled(guidance: PlaudCLIProvider.installGuidanceCommand))
    await #expect(throws: ExternalSyncProviderError.notInstalled) {
        _ = try await provider.listRecordings(since: .distantPast)
    }
}

// MARK: Pagination across the window (AC13, D-28)

@Test
func listingWalksPagesUntilTheWindowIsCoveredAndStopsAtOlderRows() async throws {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let recentDay = { (offset: Int) -> String in
        let date = calendar.date(byAdding: .day, value: -offset, to: today)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
    let runner = FakeCLIRunner()
    // Page 1 is full (pageSize 2) and recent; page 2 starts with an old row,
    // so page 3 must never be requested.
    runner.queueFiles(
        .result(CLICommandResult(exitCode: 0, stdout: filesTableOutput(rows: [
            filesTableRow(id: "id-newest", name: "A", date: recentDay(0)),
            filesTableRow(id: "id-second", name: "B", date: recentDay(1)),
        ]))),
        .result(CLICommandResult(exitCode: 0, stdout: filesTableOutput(rows: [
            filesTableRow(id: "id-ancient", name: "C", date: "2020-01-01"),
        ])))
    )
    for id in ["id-newest", "id-second"] {
        runner.respond(to: "file", with: .result(CLICommandResult(
            exitCode: 0,
            stdout: fileDetailsOutput(id: id, name: "Detail \(id)", createdAt: "-", startAt: "-")
        )))
    }
    let provider = makeProvider(runner: runner, pageSize: 2)

    let since = today.addingTimeInterval(-4 * 24 * 60 * 60)
    let recordings = try await provider.listRecordings(since: since)

    #expect(recordings.count == 2)
    #expect(Set(recordings.map(\.remoteID)) == ["id-newest", "id-second"])
    // With "-" in both timestamp fields the list-table day is the fallback
    // start time (D-16 defaulting).
    #expect(recordings.allSatisfy { $0.startedAt >= since })
    let filesCalls = runner.calls.filter { $0.first == "files" }
    #expect(filesCalls.count == 2)
    #expect(filesCalls.last?.contains("2") == true)
}
