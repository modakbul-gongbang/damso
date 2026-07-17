import Foundation
import Testing
@testable import Damso

private func mic(_ bundleID: String) -> MicProcessSnapshot {
    MicProcessSnapshot(bundleID: bundleID, isRunningInput: true)
}

private func meetTab(id: String = "t1", title: String = "주간 싱크") -> BrowserTabSnapshot {
    BrowserTabSnapshot(id: id, title: title, url: "https://meet.google.com/abc-defg-hij")
}

struct MeetingDetectionEngineTests {
    @Test
    func meetingURLPatternsMatchPRDContract() {
        #expect(MeetingDetectionEngine.meetingService(forURL: "https://meet.google.com/abc-defg-hij") == .meet)
        #expect(MeetingDetectionEngine.meetingService(forURL: "https://meet.google.com/") == nil)
        #expect(MeetingDetectionEngine.meetingService(forURL: "https://meet.google.com/landing") == nil)
        #expect(MeetingDetectionEngine.meetingService(forURL: "https://zoom.us/j/123456") == .zoom)
        #expect(MeetingDetectionEngine.meetingService(forURL: "https://us02web.zoom.us/wc/123/start") == .zoom)
        #expect(MeetingDetectionEngine.meetingService(forURL: "https://zoom.us/pricing") == nil)
        #expect(MeetingDetectionEngine.meetingService(forURL: "https://notzoom.us/j/123") == nil)
        #expect(MeetingDetectionEngine.meetingService(forURL: "https://example.com/") == nil)
    }

    @Test
    func nonMeetingMicUseIsIgnored() {
        // Voice memos and other apps using the mic never count as a meeting.
        let snapshot = MeetingDetectionSnapshot(
            micProcesses: [mic("com.apple.VoiceMemos"), mic("com.hnc.Discord")],
            zoomAppInMeeting: false,
            tabsByApp: [:]
        )
        #expect(MeetingDetectionEngine.detect(snapshot).isEmpty)
    }

    @Test
    func zoomAppNeedsInMeetingSignalBesideMicUse() {
        // Mic alone (audio test) is not a meeting.
        let audioTest = MeetingDetectionSnapshot(
            micProcesses: [mic("us.zoom.xos")],
            zoomAppInMeeting: false,
            tabsByApp: [:]
        )
        #expect(MeetingDetectionEngine.detect(audioTest).isEmpty)

        let meeting = MeetingDetectionSnapshot(
            micProcesses: [mic("us.zoom.xos")],
            zoomAppInMeeting: true,
            tabsByApp: [:]
        )
        let detected = MeetingDetectionEngine.detect(meeting)
        #expect(detected.map(\.app) == [.zoomApp])
        #expect(detected.first?.service == .zoom)
    }

    @Test
    func browserNeedsBothMicUseAndMeetingTab() {
        // Meeting tab open but mic unused (just browsing) — no detection.
        let browsing = MeetingDetectionSnapshot(
            micProcesses: [],
            zoomAppInMeeting: false,
            tabsByApp: [.chrome: [meetTab()]]
        )
        #expect(MeetingDetectionEngine.detect(browsing).isEmpty)

        // Chrome mic in use but no meeting tab (Discord web etc.) — no detection.
        let voiceChat = MeetingDetectionSnapshot(
            micProcesses: [mic("com.google.Chrome")],
            zoomAppInMeeting: false,
            tabsByApp: [.chrome: [BrowserTabSnapshot(id: "t9", title: "Discord", url: "https://discord.com/channels/1")]]
        )
        #expect(MeetingDetectionEngine.detect(voiceChat).isEmpty)

        // Both signals present — detected with tab identity and title hint.
        let meeting = MeetingDetectionSnapshot(
            micProcesses: [mic("com.google.Chrome")],
            zoomAppInMeeting: false,
            tabsByApp: [.chrome: [meetTab(id: "42", title: "주간 싱크")]]
        )
        let detected = MeetingDetectionEngine.detect(meeting)
        #expect(detected.count == 1)
        #expect(detected.first?.app == .chrome)
        #expect(detected.first?.service == .meet)
        #expect(detected.first?.tabID == "42")
        #expect(detected.first?.titleHint == "Chrome · 주간 싱크")
    }

    @Test
    func multipleMeetingTabsUseOnlyTheFirstDetectedTab() {
        let snapshot = MeetingDetectionSnapshot(
            micProcesses: [mic("com.google.Chrome")],
            zoomAppInMeeting: false,
            tabsByApp: [.chrome: [meetTab(id: "first"), meetTab(id: "second")]]
        )
        let detected = MeetingDetectionEngine.detect(snapshot)
        #expect(detected.count == 1)
        #expect(detected.first?.tabID == "first")
    }

    @Test
    func diaArcAndSafariAreDetectedByTheirOwnSignals() {
        let snapshot = MeetingDetectionSnapshot(
            micProcesses: [mic("company.thebrowser.dia"), mic("company.thebrowser.Browser.helper"), mic("com.apple.WebKit.GPU")],
            zoomAppInMeeting: false,
            tabsByApp: [
                .dia: [meetTab(id: "d1")],
                .arc: [meetTab(id: "a1")],
                .safari: [BrowserTabSnapshot(id: "s1", title: "Zoom", url: "https://us02web.zoom.us/j/555")],
            ]
        )
        let detected = MeetingDetectionEngine.detect(snapshot)
        #expect(Set(detected.map(\.app)) == Set([.dia, .arc, .safari]))
    }

    @Test
    func diaMicUseReportsTheSharedArcCoreHelperBundle() {
        // Regression for the real signal measured live on 2026-07-17: Dia
        // holds the microphone through ArcCore's shared helper, whose bundle
        // is `company.thebrowser.browser.helper` (not `...dia`).
        let snapshot = MeetingDetectionSnapshot(
            micProcesses: [mic("company.thebrowser.browser.helper")],
            zoomAppInMeeting: false,
            tabsByApp: [.dia: [meetTab(id: "d1", title: "실측 미팅")]]
        )
        let detected = MeetingDetectionEngine.detect(snapshot)
        #expect(detected.map(\.app) == [.dia])
        #expect(detected.first?.tabID == "d1")
    }
}

struct MeetingDetectionSessionTests {
    private let chrome = DetectedMeetingSource(app: .chrome, service: .meet, titleHint: "Chrome · 주간 싱크", tabID: "42")
    private let zoom = DetectedMeetingSource(app: .zoomApp, service: .zoom, titleHint: "Zoom", tabID: nil)
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test
    func detectionPromptsAndApprovalStartsRecording() {
        var machine = MeetingSessionStateMachine()
        #expect(machine.observe(sources: [chrome], at: at(0)).isEmpty)
        guard case .prompting(let session, _) = machine.state else {
            Issue.record("expected prompting state")
            return
        }
        #expect(session.representative == chrome)

        let effects = machine.approveRecording(at: at(30))
        guard case .startRecording(let started) = effects.first else {
            Issue.record("expected startRecording effect")
            return
        }
        #expect(started.recordingStartedAt == at(30))
        guard case .recording = machine.state else {
            Issue.record("expected recording state")
            return
        }
    }

    @Test
    func micDropShorterThanGraceContinuesTheSameRecording() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        _ = machine.approveRecording(at: at(0))
        guard case .recording(let original) = machine.state else {
            Issue.record("expected recording")
            return
        }

        // Mic drops, comes back after 45s: still the same session/recording.
        #expect(machine.observe(sources: [], at: at(100)).isEmpty)
        #expect(machine.observe(sources: [], at: at(130)).isEmpty)
        #expect(machine.observe(sources: [chrome], at: at(145)).isEmpty)
        guard case .recording(let resumed) = machine.state else {
            Issue.record("expected recording after resume")
            return
        }
        #expect(resumed.id == original.id)
    }

    @Test
    func graceExpiryStopsAndProcessesLongRecordings() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        _ = machine.approveRecording(at: at(0))
        _ = machine.observe(sources: [], at: at(400))
        let effects = machine.observe(sources: [], at: at(461))
        #expect(effects.count == 2)
        guard case .stopRecording = effects[0], case .processRecording = effects[1] else {
            Issue.record("expected stop then process, got \(effects)")
            return
        }
        #expect(machine.state == .idle)
    }

    @Test
    func simultaneousMeetingsMergeIntoOneSessionWithStableRepresentative() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [zoom], at: at(0))
        _ = machine.approveRecording(at: at(5))
        _ = machine.observe(sources: [zoom, chrome], at: at(30))
        guard case .recording(let session) = machine.state else {
            Issue.record("expected recording")
            return
        }
        #expect(session.representative == zoom)
        #expect(session.sources.count == 2)

        // Zoom ends but Chrome continues: still recording, no grace yet.
        _ = machine.observe(sources: [chrome], at: at(60))
        guard case .recording = machine.state else {
            Issue.record("expected recording while one source remains")
            return
        }

        // All sources end: grace begins, then the session finishes once.
        _ = machine.observe(sources: [], at: at(400))
        let effects = machine.observe(sources: [], at: at(465))
        #expect(effects.contains { if case .stopRecording = $0 { true } else { false } })
    }

    @Test
    func ignoredPromptStaysAvailableForLateStart() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        // Meeting runs on; no re-prompt, panel state remains prompting.
        _ = machine.observe(sources: [chrome], at: at(600))
        guard case .prompting(let session, _) = machine.state else {
            Issue.record("expected prompting")
            return
        }
        #expect(session.firstDetectedAt == at(0))

        // Late start mid-meeting records from now on.
        let effects = machine.approveRecording(at: at(700))
        #expect(effects.count == 1)
        guard case .recording(let recording) = machine.state else {
            Issue.record("expected recording")
            return
        }
        #expect(recording.recordingStartedAt == at(700))
    }

    @Test
    func promptWithoutApprovalDismissesAfterQuietGrace() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        _ = machine.observe(sources: [], at: at(100))
        // Within the quiet grace the session (and panel) survives.
        _ = machine.observe(sources: [chrome], at: at(130))
        guard case .prompting = machine.state else {
            Issue.record("expected prompting to survive a short mic drop")
            return
        }
        _ = machine.observe(sources: [], at: at(200))
        _ = machine.observe(sources: [], at: at(261))
        #expect(machine.state == .idle)
    }

    @Test
    func stopButtonEndsImmediatelyWithoutGrace() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        _ = machine.approveRecording(at: at(0))
        let effects = machine.stopPressed(at: at(400))
        #expect(effects.count == 2)
        guard case .stopRecording = effects[0], case .processRecording = effects[1] else {
            Issue.record("expected immediate stop then process")
            return
        }
    }

    @Test
    func shortRecordingEntersDiscardConfirmation() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        _ = machine.approveRecording(at: at(0))
        let effects = machine.stopPressed(at: at(299))
        #expect(effects.count == 1)
        guard case .stopRecording = effects[0] else {
            Issue.record("expected stop only")
            return
        }
        guard case .shortRecordingConfirm(_, let duration, let deadline) = machine.state else {
            Issue.record("expected short recording confirmation")
            return
        }
        #expect(duration == 299)
        #expect(deadline == at(299 + 300))
    }

    @Test
    func exactCutoffBoundaryProcessesWithoutConfirmation() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        _ = machine.approveRecording(at: at(0))
        let effects = machine.stopPressed(at: at(300))
        #expect(effects.count == 2)
    }

    @Test
    func keepAnywayProcessesTheShortRecording() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        _ = machine.approveRecording(at: at(0))
        _ = machine.stopPressed(at: at(100))
        let effects = machine.keepShortRecording()
        guard case .processRecording = effects.first else {
            Issue.record("expected processRecording")
            return
        }
        #expect(machine.state == .idle)
    }

    @Test
    func discardAndTimeoutBothDiscardTheShortRecording() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        _ = machine.approveRecording(at: at(0))
        _ = machine.stopPressed(at: at(100))
        let manual = machine.discardShortRecording()
        guard case .discardRecording = manual.first else {
            Issue.record("expected discardRecording")
            return
        }

        // No-response timeout path.
        var timed = MeetingSessionStateMachine()
        _ = timed.observe(sources: [chrome], at: at(0))
        _ = timed.approveRecording(at: at(0))
        _ = timed.stopPressed(at: at(100))
        let effects = timed.observe(sources: [], at: at(100 + 301))
        guard case .discardRecording = effects.first else {
            Issue.record("expected auto discard after timeout")
            return
        }
        #expect(timed.state == .idle)
    }
}

// MARK: - Chromux live pairing gate

/// `chromux tabs` force-launches the user's real Chrome on a cold start, so
/// every passive surface (detection loop, menu bar card, Settings) must gate
/// on the ps-based relay status, which never launches anything.
struct ChromuxLivePairingParseTests {
    @Test
    func connectedLiveRelayIsRecognized() {
        let json = """
        {"ok": true, "profiles": [
            {"profile": "default", "status": "running", "launchMode": "headed"},
            {"profile": "live", "status": "running", "launchMode": "live", "extension": "connected", "tabs": "12"}
        ]}
        """
        #expect(ChromuxLivePairing.parse(Data(json.utf8)).relayConnected)
    }

    @Test
    func waitingKillSwitchMissingLiveRowAndBrokenOutputAllReadAsDisconnected() {
        let waiting = """
        {"ok": true, "profiles": [{"profile": "live", "extension": "waiting"}]}
        """
        #expect(!ChromuxLivePairing.parse(Data(waiting.utf8)).relayConnected)
        let killSwitch = """
        {"ok": true, "profiles": [{"profile": "live", "extension": "kill-switch"}]}
        """
        #expect(!ChromuxLivePairing.parse(Data(killSwitch.utf8)).relayConnected)
        let noLive = """
        {"ok": true, "profiles": [{"profile": "default", "status": "running"}]}
        """
        #expect(!ChromuxLivePairing.parse(Data(noLive.utf8)).relayConnected)
        #expect(!ChromuxLivePairing.parse(nil).relayConnected)
        #expect(!ChromuxLivePairing.parse(Data("not json".utf8)).relayConnected)
    }
}

// MARK: - Chrome probe fallback (chromux optional)

private struct StubTabProbe: BrowserTabProbing {
    let result: [BrowserTabSnapshot]
    func tabs() async -> [BrowserTabSnapshot] { result }
}

/// chromux pairing is optional: with the relay connected the chromux listing
/// (capture-capable numeric tab ids) wins; without it the AppleScript
/// fallback still detects the Meet tab, and its prefixed ids are excluded
/// from capture attachment.
struct ChromeTabProbeFallbackTests {
    @Test
    func chromuxListingWinsWhenAvailable() async {
        let chromuxTab = BrowserTabSnapshot(id: "412", title: "Meet", url: "https://meet.google.com/abc-defg-hij")
        let probe = ChromeTabProbe(
            primary: StubTabProbe(result: [chromuxTab]),
            fallback: StubTabProbe(result: [BrowserTabSnapshot(id: "applescript:0", title: "x", url: "https://example.com")])
        )
        #expect(await probe.tabs() == [chromuxTab])
    }

    @Test
    func appleScriptFallbackDetectsWithoutPairingButNeverFeedsCapture() async {
        let fallbackTab = BrowserTabSnapshot(id: "applescript:0", title: "Meet", url: "https://meet.google.com/abc-defg-hij")
        let probe = ChromeTabProbe(primary: StubTabProbe(result: []), fallback: StubTabProbe(result: [fallbackTab]))
        let tabs = await probe.tabs()
        #expect(tabs == [fallbackTab])

        // The detection engine accepts the fallback tab...
        let snapshot = MeetingDetectionSnapshot(
            micProcesses: [MicProcessSnapshot(bundleID: "com.google.Chrome.helper", isRunningInput: true)],
            zoomAppInMeeting: false,
            tabsByApp: [.chrome: tabs]
        )
        let detected = MeetingDetectionEngine.detect(snapshot)
        #expect(detected.first?.service == .meet)
        // ...while its id stays recognizable as non-attachable for capture.
        #expect(detected.first?.tabID?.hasPrefix(ChromeAppleScriptTabProbe.idPrefix) == true)
    }
}
