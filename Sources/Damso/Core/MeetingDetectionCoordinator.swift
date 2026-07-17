import AppKit
import Foundation
import OSLog

/// Settings for the meeting detection daemon (R8). Both default to on:
/// detection ships enabled with non-blocking degrade.
enum MeetingDetectionPreferences {
    static let detectionEnabledKey = "damso.meetingDetectionEnabled"
    static let participantCaptureEnabledKey = "damso.participantCaptureEnabled"

    static func isDetectionEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: detectionEnabledKey) == nil ? true : defaults.bool(forKey: detectionEnabledKey)
    }

    static func isParticipantCaptureEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: participantCaptureEnabledKey) == nil ? true : defaults.bool(forKey: participantCaptureEnabledKey)
    }

    static func setDetectionEnabled(_ enabled: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: detectionEnabledKey)
    }

    static func setParticipantCaptureEnabled(_ enabled: Bool, _ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: participantCaptureEnabledKey)
    }
}

/// The resident detection daemon: polls the probes, runs the pure engine and
/// session state machine, drives the floating panel, and forwards approved
/// session transitions into the existing recording pipeline. Nothing records
/// or attaches before the user presses [녹음] (guardrail G4).
@MainActor
final class MeetingDetectionCoordinator: ObservableObject {
    private static let logger = Logger(subsystem: "com.yansfil.damso", category: "detection")

    /// One line for the menu bar so detection state and failures stay visible
    /// instead of being swallowed (guardrail G6).
    @Published private(set) var statusLine: String?

    private let workspace: MeetingWorkspaceController
    private let panel: MeetingPromptPanelController

    /// The floating panel's presentational model, shared with the menu-bar
    /// popover so both surfaces mirror the same session phase and actions.
    var panelModel: MeetingPromptPanelModel { panel.model }
    private let micProbe: any MicActivityProbing
    private let zoomProbe: any ZoomAppMeetingProbing
    private let tabProbes: [MeetingSourceApp: any BrowserTabProbing]
    private let pollIntervalSeconds: TimeInterval

    private var machine = MeetingSessionStateMachine()
    private var pollTask: Task<Void, Never>?
    /// Verification-only injection (V7): when set, the poll loop uses these
    /// sources instead of the real probes. The detection-enabled preference
    /// still gates them, so the settings toggle is tested honestly.
    var simulatedSources: [DetectedMeetingSource]?
    /// The session the user pressed [무시] on; the panel collapses but stays.
    private var ignoredSessionID: UUID?
    /// Set by the participant capture pipeline (N4) while a live count exists.
    private(set) var participantCount: Int?
    private(set) var showPairingHint = false
    /// Participant capture wiring (T4): called on recording start/stop with
    /// the session and the record's directory.
    var onRecordingStarted: ((MeetingSessionInfo, URL?) -> Void)?
    var onRecordingEnded: (() -> Void)?

    init(
        workspace: MeetingWorkspaceController,
        panel: MeetingPromptPanelController = MeetingPromptPanelController(),
        micProbe: any MicActivityProbing = CoreAudioMicActivityProbe(),
        zoomProbe: any ZoomAppMeetingProbing = SystemZoomAppMeetingProbe(),
        tabProbes: [MeetingSourceApp: any BrowserTabProbing]? = nil,
        pollIntervalSeconds: TimeInterval = 5
    ) {
        self.workspace = workspace
        self.panel = panel
        self.micProbe = micProbe
        self.zoomProbe = zoomProbe
        self.tabProbes = tabProbes ?? [
            .chrome: ChromuxTabProbe(),
            .dia: ChromuxTabProbe(),
            .arc: ChromuxTabProbe(),
            .safari: SafariTabProbe(),
        ]
        self.pollIntervalSeconds = pollIntervalSeconds
        wirePanelActions()
    }

    func startMonitoring() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce(at: Date())
                try? await Task.sleep(for: .seconds(self?.pollIntervalSeconds ?? 5))
            }
        }
    }

    func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One detection cycle. Exposed for the runtime simulation used by V7.
    func pollOnce(at now: Date) async {
        guard MeetingDetectionPreferences.isDetectionEnabled() else {
            // Detection off: never prompt. An approved recording keeps
            // running (the user consented to it); prompting sessions end.
            if case .prompting = machine.state {
                machine = MeetingSessionStateMachine()
            }
            if case .idle = machine.state {
                statusLine = Loc.tr("Meeting detection is off")
                render()
                return
            }
            await advance(sources: currentSourcesFromState(), at: now)
            return
        }
        let sources: [DetectedMeetingSource]
        if let simulatedSources {
            sources = simulatedSources
        } else {
            sources = await detectSources()
        }
        await advance(sources: sources, at: now)
    }

    /// Drives the state machine with an explicit source list. Used by the
    /// simulation path (V7) to inject synthetic detection signals.
    func advance(sources: [DetectedMeetingSource], at now: Date) async {
        let effects = machine.observe(sources: sources, at: now)
        await apply(effects)
        render()
        updateStatusLine()
    }

    private func detectSources() async -> [DetectedMeetingSource] {
        let micProcesses = micProbe.micProcesses()
        var tabsByApp: [MeetingSourceApp: [BrowserTabSnapshot]] = [:]
        var snapshot = MeetingDetectionSnapshot(micProcesses: micProcesses, zoomAppInMeeting: false, tabsByApp: [:])
        // Probe tabs only for browsers actually using the mic; a failed or
        // missing probe reads as no tabs and can never block detection (G6).
        for (app, probe) in tabProbes where MeetingDetectionEngine.micInUse(by: app, in: snapshot) {
            tabsByApp[app] = await probe.tabs()
        }
        snapshot.tabsByApp = tabsByApp
        if MeetingDetectionEngine.micInUse(by: .zoomApp, in: snapshot) {
            snapshot.zoomAppInMeeting = zoomProbe.zoomAppInMeeting()
        }
        return MeetingDetectionEngine.detect(snapshot)
    }

    /// When detection is disabled mid-recording we stop feeding fresh probe
    /// data and replay the session's own sources so grace-based ending still
    /// works once the meeting actually ends.
    private func currentSourcesFromState() -> [DetectedMeetingSource] {
        switch machine.state {
        case .recording(let session), .grace(let session, _):
            return session.sources
        default:
            return []
        }
    }

    private func apply(_ effects: [MeetingSessionEffect]) async {
        for effect in effects {
            switch effect {
            case .startRecording(let session):
                let started = await workspace.detectionStartRecording()
                if started {
                    Self.logger.notice("detection_recording_started")
                    onRecordingStarted?(session, workspace.activeRecordingDirectory())
                } else {
                    Self.logger.error("detection_recording_start_failed")
                    machine.recordingFailedToStart()
                }
            case .stopRecording:
                onRecordingEnded?()
                participantCount = nil
                _ = await workspace.detectionStopRecording()
            case .processRecording:
                workspace.detectionProcessStoppedRecording()
            case .discardRecording:
                workspace.detectionDiscardStoppedRecording()
            }
        }
    }

    // MARK: Panel

    private func wirePanelActions() {
        panel.model.actions = MeetingPromptPanelActions(
            record: { [weak self] in
                guard let self else { return }
                Task {
                    await self.apply(self.machine.approveRecording(at: Date()))
                    self.render()
                }
            },
            ignore: { [weak self] in
                guard let self else { return }
                if case .prompting(let session, _) = machine.state {
                    ignoredSessionID = session.id
                }
                render()
            },
            stop: { [weak self] in
                guard let self else { return }
                Task {
                    await self.apply(self.machine.stopPressed(at: Date()))
                    self.render()
                }
            },
            discard: { [weak self] in
                guard let self else { return }
                Task {
                    await self.apply(self.machine.discardShortRecording())
                    self.render()
                }
            },
            keep: { [weak self] in
                guard let self else { return }
                Task {
                    await self.apply(self.machine.keepShortRecording())
                    self.render()
                }
            },
            openCaptureSettings: {
                NSApp.activate(ignoringOtherApps: true)
                // Send after activation lands: from the non-activating panel
                // the responder chain may not route the selector immediately.
                DispatchQueue.main.async {
                    if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                        _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
            }
        )
    }

    func updateParticipantCount(_ count: Int?) {
        participantCount = count
        render()
    }

    func updatePairingHint(_ show: Bool) {
        showPairingHint = show
        render()
    }

    private func render() {
        switch machine.state {
        case .idle:
            panel.render(phase: nil)
        case .prompting(let session, _):
            panel.render(phase: .proposal(
                titleHint: session.representative.titleHint,
                app: session.representative.app,
                collapsed: ignoredSessionID == session.id
            ))
        case .recording(let session), .grace(let session, _):
            panel.render(phase: .recording(
                startedAt: session.recordingStartedAt ?? Date(),
                participantCount: participantCount,
                showPairingHint: showPairingHint
            ))
        case .shortRecordingConfirm(_, let duration, _):
            panel.render(phase: .shortConfirm(durationSeconds: Int(duration)))
        }
    }

    private func updateStatusLine() {
        switch machine.state {
        case .idle:
            statusLine = MeetingDetectionPreferences.isDetectionEnabled()
                ? Loc.tr("Watching for meetings")
                : Loc.tr("Meeting detection is off")
        case .prompting(let session, _):
            statusLine = String(format: Loc.tr("Meeting detected: %@"), session.representative.titleHint)
        case .recording, .grace:
            statusLine = Loc.tr("Recording a detected meeting")
        case .shortRecordingConfirm:
            statusLine = Loc.tr("Short recording needs a decision")
        }
    }
}
