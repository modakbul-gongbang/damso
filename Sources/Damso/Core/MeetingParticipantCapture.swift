import Foundation
import OSLog

/// One captured participant in participants.json:
/// {name, firstSeenAt, lastSeenAt, source, speakingSamples?}.
/// `speakingSamples` are offsets in seconds from recording start at which
/// this participant was the active speaker, ready for the diarization
/// time-axis majority vote.
struct MeetingParticipantRecord: Codable, Equatable, Sendable {
    var name: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    var source: String
    var speakingSamples: [Double]?
}

/// Wire format of participants.json. A missing or empty file is always valid
/// for the pipeline (R5).
struct MeetingParticipantsFile: Codable, Equatable, Sendable {
    var version: Int = 1
    var participants: [MeetingParticipantRecord] = []

    static func read(from url: URL) -> MeetingParticipantsFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        DateCoding.configure(decoder)
        return try? decoder.decode(MeetingParticipantsFile.self, from: data)
    }
}

/// Pure accumulation of poll results into participant records: dedup by
/// exact display name, first/last seen bookkeeping, and active-speaker
/// sample offsets. Fully covered by synthetic-fixture tests (V4).
struct ParticipantCaptureRecorder: Sendable {
    private(set) var file = MeetingParticipantsFile()
    let source: String

    init(source: String) {
        self.source = source
    }

    /// A participant-name poll result (every 30s). Late joiners append; known
    /// names only advance lastSeenAt.
    mutating func observe(names: [String], at now: Date) {
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            if let index = file.participants.firstIndex(where: { $0.name == name }) {
                file.participants[index].lastSeenAt = now
            } else {
                file.participants.append(MeetingParticipantRecord(
                    name: name,
                    firstSeenAt: now,
                    lastSeenAt: now,
                    source: source,
                    speakingSamples: nil
                ))
            }
        }
    }

    /// An active-speaker sample (every 1-2s, Meet only). Speakers not yet in
    /// the participant list are added too — the sampling proves presence.
    mutating func observeActiveSpeakers(_ names: [String], atOffset offset: Double, at now: Date) {
        observe(names: names, at: now)
        for raw in names {
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let index = file.participants.firstIndex(where: { $0.name == name }) else { continue }
            var samples = file.participants[index].speakingSamples ?? []
            samples.append(offset)
            file.participants[index].speakingSamples = samples
        }
    }

    var participantCount: Int {
        file.participants.count
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        DateCoding.configure(encoder)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(file)
    }
}

// MARK: - Live provider

/// The narrow chromux boundary the capture loop talks to; tests substitute a
/// synthetic provider so capture behavior is provable without a browser.
protocol ParticipantSnapshotProviding: Sendable {
    /// Attaches to the meeting tab. False means degrade: recording continues,
    /// capture retries later (R5: 5s timeout, non-blocking).
    func attach() async -> Bool
    func participantNames() async -> [String]?
    func activeSpeakerNames() async -> [String]?
    func detach() async
}

/// Attaches to the user's real Chrome tab through chromux live mode and runs
/// the capture page scripts. All calls are bounded and failure-tolerant.
struct ChromuxParticipantProvider: ParticipantSnapshotProviding {
    let tabID: String
    let service: MeetingService
    var attachTimeoutSeconds: TimeInterval = 5
    var scriptTimeoutSeconds: TimeInterval = 5

    private var sessionName: String { "damso-capture" }
    private var liveEnvironment: [String: String] { ["CHROMUX_PROFILE": "live"] }

    func attach() async -> Bool {
        let result = await MeetingProbeSubprocess.run(
            arguments: ["chromux", "open", sessionName, "--tab", tabID],
            timeoutSeconds: attachTimeoutSeconds,
            environmentOverrides: liveEnvironment
        )
        return result != nil
    }

    func participantNames() async -> [String]? {
        let script = service == .meet ? MeetingDOMScripts.meetParticipants : MeetingDOMScripts.zoomWebParticipants
        guard let data = await runScript(script) else { return nil }
        return MeetingDOMScriptOutput.participantNames(from: data)
    }

    func activeSpeakerNames() async -> [String]? {
        guard service == .meet else { return nil }
        guard let data = await runScript(MeetingDOMScripts.meetActiveSpeakers) else { return nil }
        return MeetingDOMScriptOutput.activeSpeakerNames(from: data)
    }

    func detach() async {
        _ = await MeetingProbeSubprocess.run(
            arguments: ["chromux", "close", sessionName],
            timeoutSeconds: attachTimeoutSeconds,
            environmentOverrides: liveEnvironment
        )
    }

    private func runScript(_ script: String) async -> Data? {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("damso-capture-\(UUID().uuidString).js")
        defer { try? FileManager.default.removeItem(at: scriptURL) }
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }
        return await MeetingProbeSubprocess.run(
            arguments: ["chromux", "run", sessionName, "--page-file", scriptURL.path],
            timeoutSeconds: scriptTimeoutSeconds,
            environmentOverrides: liveEnvironment
        )
    }
}

// MARK: - Capture session controller

/// Drives one recording's participant capture: attach (with retry), the 30s
/// participant poll, the 1-2s Meet active-speaker sampling, and atomic
/// participants.json writes into the meeting folder. Capture failures only
/// degrade capture — recording is never blocked (R5, G6).
@MainActor
final class MeetingParticipantCaptureController {
    private static let logger = Logger(subsystem: "com.yansfil.damso", category: "participant-capture")

    /// PRD-fixed cadences (tests inject faster ones).
    static let participantPollSeconds: TimeInterval = 30
    static let activeSpeakerSampleSeconds: TimeInterval = 1.5
    static let attachRetrySeconds: TimeInterval = 30

    private let provider: any ParticipantSnapshotProviding
    private let recordingDirectory: URL
    private let recordingStartedAt: Date
    private let pollInterval: TimeInterval
    private let sampleInterval: TimeInterval
    private let attachRetryInterval: TimeInterval
    private var recorder: ParticipantCaptureRecorder
    private var pollTask: Task<Void, Never>?
    private var samplingTask: Task<Void, Never>?
    private var attached = false
    /// Reports (participantCount, captureHealthy) so the panel can show the
    /// live count and the pairing hint.
    var onStatus: ((Int?, Bool) -> Void)?

    init(
        provider: any ParticipantSnapshotProviding,
        recordingDirectory: URL,
        recordingStartedAt: Date,
        source: String,
        pollInterval: TimeInterval = MeetingParticipantCaptureController.participantPollSeconds,
        sampleInterval: TimeInterval = MeetingParticipantCaptureController.activeSpeakerSampleSeconds,
        attachRetryInterval: TimeInterval = MeetingParticipantCaptureController.attachRetrySeconds
    ) {
        self.provider = provider
        self.recordingDirectory = recordingDirectory
        self.recordingStartedAt = recordingStartedAt
        self.pollInterval = pollInterval
        self.sampleInterval = sampleInterval
        self.attachRetryInterval = attachRetryInterval
        recorder = ParticipantCaptureRecorder(source: source)
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            await self?.runPollLoop()
        }
    }

    func stop() {
        pollTask?.cancel()
        samplingTask?.cancel()
        pollTask = nil
        samplingTask = nil
        persist()
        let provider = provider
        Task.detached { await provider.detach() }
    }

    private func runPollLoop() async {
        while !Task.isCancelled {
            if !attached {
                attached = await provider.attach()
                if !attached {
                    Self.logger.notice("participant_capture_attach_failed retry_in=\(Int(self.attachRetryInterval))s")
                    onStatus?(recorder.participantCount > 0 ? recorder.participantCount : nil, false)
                    try? await Task.sleep(for: .seconds(attachRetryInterval))
                    continue
                }
                Self.logger.notice("participant_capture_attached")
                startSamplingIfNeeded()
            }
            if let names = await provider.participantNames() {
                recorder.observe(names: names, at: Date())
                persist()
                onStatus?(recorder.participantCount, true)
            } else {
                // Lost the tab or the script failed: fall back to re-attach,
                // keeping everything captured so far (partial data is valid).
                attached = false
                samplingTask?.cancel()
                samplingTask = nil
                onStatus?(recorder.participantCount, false)
                continue
            }
            try? await Task.sleep(for: .seconds(pollInterval))
        }
    }

    private func startSamplingIfNeeded() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            await self?.runSamplingLoop()
        }
    }

    private func runSamplingLoop() async {
        while !Task.isCancelled {
            if let names = await provider.activeSpeakerNames(), !names.isEmpty {
                let now = Date()
                recorder.observeActiveSpeakers(names, atOffset: now.timeIntervalSince(recordingStartedAt), at: now)
            }
            try? await Task.sleep(for: .seconds(sampleInterval))
        }
    }

    private func persist() {
        guard recorder.participantCount > 0 else { return }
        do {
            let data = try recorder.encoded()
            let url = recordingDirectory.appendingPathComponent("participants.json")
            try data.write(to: url, options: .atomic)
        } catch {
            Self.logger.error("participants_json_write_failed")
        }
    }
}

/// Connects the detection coordinator to participant capture (T4): on
/// recording start, attach to the first-detected Chrome meeting tab if
/// capture is enabled; on end, stop and finalize participants.json.
@MainActor
enum MeetingParticipantCaptureWiring {
    private static var active: MeetingParticipantCaptureController?

    static func attach(to coordinator: MeetingDetectionCoordinator) {
        coordinator.onRecordingStarted = { [weak coordinator] session, directory in
            guard let coordinator else { return }
            guard MeetingDetectionPreferences.isParticipantCaptureEnabled() else { return }
            // Capture runs over the chromux live channel: any Chromium
            // browser the user pairs (Chrome/Dia/Arc; Dia confirmed live on
            // 2026-07-17, user-approved Arc inclusion). Safari and the Zoom
            // app have no capture channel; recording proceeds without
            // capture and the panel hints.
            // AppleScript-sourced tab ids ("applescript:N") detect the
            // meeting but cannot be attached over the chromux channel;
            // recording proceeds without capture and the pairing hint shows.
            guard let source = session.sources.first(where: { source in
                guard source.app.usesChromux, let tabID = source.tabID else { return false }
                return !tabID.hasPrefix(ChromeAppleScriptTabProbe.idPrefix)
            }),
                  let tabID = source.tabID,
                  let directory else {
                coordinator.updatePairingHint(true)
                return
            }
            let controller = MeetingParticipantCaptureController(
                provider: ChromuxParticipantProvider(tabID: tabID, service: source.service),
                recordingDirectory: directory,
                recordingStartedAt: session.recordingStartedAt ?? Date(),
                source: "\(source.app.rawValue)-\(source.service.rawValue)"
            )
            controller.onStatus = { [weak coordinator] count, healthy in
                coordinator?.updateParticipantCount(count)
                coordinator?.updatePairingHint(!healthy)
            }
            active = controller
            controller.start()
        }
        coordinator.onRecordingEnded = {
            active?.stop()
            active = nil
        }
    }
}
