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
    func meetingIdentityIgnoresQueryAndFragmentNoise() {
        #expect(
            MeetingDetectionEngine.meetingIdentity(forURL: "https://meet.google.com/abc-defg-hij?authuser=1#chat")
                == MeetingDetectionEngine.meetingIdentity(forURL: "https://meet.google.com/abc-defg-hij")
        )
        #expect(
            MeetingDetectionEngine.meetingIdentity(forURL: "https://us02web.zoom.us/wc/123/start?from=join")
                == MeetingDetectionEngine.meetingIdentity(forURL: "https://us02web.zoom.us/wc/123/start")
        )
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
    func activeMeetingTabWinsOverAnEarlierStaleMeetingTab() {
        let stale = BrowserTabSnapshot(
            id: "old",
            title: "이전 미팅",
            url: "https://meet.google.com/old-room-code"
        )
        let current = BrowserTabSnapshot(
            id: "new",
            title: "현재 미팅",
            url: "https://meet.google.com/new-room-code",
            isActive: true
        )
        let snapshot = MeetingDetectionSnapshot(
            micProcesses: [mic("com.google.Chrome")],
            zoomAppInMeeting: false,
            tabsByApp: [.chrome: [stale, current]]
        )

        let detected = MeetingDetectionEngine.detect(snapshot)
        #expect(detected.first?.tabID == "new")
        #expect(detected.first?.meetingID == "meet:new-room-code")
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
    func ignoredPromptDisappearsAndStaysSuppressedForTheSameMeeting() {
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        machine.ignorePrompt()
        #expect(machine.state == .idle)

        _ = machine.observe(sources: [chrome], at: at(600))
        #expect(machine.state == .idle)
    }

    @Test
    func aDifferentMeetingPromptsImmediatelyWhileTheIgnoredMeetingIsStillOpen() {
        let other = DetectedMeetingSource(
            app: .chrome,
            service: .meet,
            titleHint: "Chrome · 다른 미팅",
            tabID: "84",
            meetingID: "meet.google.com/other-room"
        )
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        machine.ignorePrompt()

        _ = machine.observe(sources: [chrome, other], at: at(5))
        guard case .prompting(let session, _) = machine.state else {
            Issue.record("expected the different meeting to prompt")
            return
        }
        #expect(session.representative == other)
        #expect(session.sources == [other])
    }

    @Test
    func theSameRoomInAnotherBrowserPromptsAfterIgnoringThePreviousBrowser() {
        let dia = DetectedMeetingSource(
            app: .dia,
            service: .meet,
            titleHint: "Dia · 주간 싱크",
            tabID: "dia-tab",
            meetingID: "meet:abc-defg-hij"
        )
        let chrome = DetectedMeetingSource(
            app: .chrome,
            service: .meet,
            titleHint: "Chrome · 주간 싱크",
            tabID: "chrome-tab",
            meetingID: "meet:abc-defg-hij"
        )
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [dia], at: at(0))
        machine.ignorePrompt()

        _ = machine.observe(sources: [chrome], at: at(5))

        guard case .prompting(let session, _) = machine.state else {
            Issue.record("the same room in a different browser should prompt")
            return
        }
        #expect(session.representative == chrome)
    }

    @Test
    func ignoredMeetingCanPromptAgainAfterItActuallyEnds() {
        var machine = MeetingSessionStateMachine(promptDismissGraceSeconds: 60)
        _ = machine.observe(sources: [chrome], at: at(0))
        machine.ignorePrompt()
        _ = machine.observe(sources: [], at: at(10))
        _ = machine.observe(sources: [], at: at(71))
        #expect(machine.state == .idle)

        _ = machine.observe(sources: [chrome], at: at(72))
        guard case .prompting = machine.state else {
            Issue.record("ended meeting should be eligible for a future prompt")
            return
        }
    }

    @Test
    func ignoredMeetingIdentitySurvivesTabAndTitleChanges() {
        let first = DetectedMeetingSource(
            app: .chrome,
            service: .meet,
            titleHint: "Chrome · 입장 중",
            tabID: "42",
            meetingID: "meet.google.com/abc-defg-hij"
        )
        let updated = DetectedMeetingSource(
            app: .chrome,
            service: .meet,
            titleHint: "Chrome · 주간 싱크",
            tabID: "99",
            meetingID: "meet.google.com/abc-defg-hij"
        )
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [first], at: at(0))
        machine.ignorePrompt()
        _ = machine.observe(sources: [updated], at: at(5))

        #expect(machine.state == .idle)
    }

    @Test
    func multipleIgnoredMeetingsRemainSuppressedTogether() {
        let other = DetectedMeetingSource(
            app: .chrome,
            service: .meet,
            titleHint: "Chrome · 다른 미팅",
            tabID: "84",
            meetingID: "meet:other-room"
        )
        var machine = MeetingSessionStateMachine()
        _ = machine.observe(sources: [chrome], at: at(0))
        machine.ignorePrompt()

        _ = machine.observe(sources: [chrome, other], at: at(5))
        guard case .prompting(let session, _) = machine.state else {
            Issue.record("expected the second meeting to prompt")
            return
        }
        #expect(session.representative == other)
        machine.ignorePrompt()

        _ = machine.observe(sources: [chrome, other], at: at(10))
        #expect(machine.state == .idle)
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
/// on a status path that never launches anything.
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

    @Test
    func missingLivePSRowFallsBackToTheVerifiedLocalBridge() {
        let observedPS = """
        {"ok": true, "profiles": [
            {"profile": "default", "status": "running", "launchMode": "headed"}
        ]}
        """
        let bridgeVersion = """
        {"Browser": "chromux-live-bridge", "Protocol-Version": "1.3"}
        """
        let relayStatus = """
        {"extensionConnected": true, "killSwitchAt": null, "tabs": 61}
        """

        let status = ChromuxLivePairing.resolve(
            psData: Data(observedPS.utf8),
            bridgeVersionData: Data(bridgeVersion.utf8),
            relayStatusData: Data(relayStatus.utf8)
        )

        #expect(status.relayConnected)
    }

    @Test
    func localPortMustIdentifyAConnectedChromuxBridge() {
        let observedPS = """
        {"ok": true, "profiles": [{"profile": "default", "status": "running"}]}
        """
        let unrelatedServer = """
        {"Browser": "unrelated-local-service"}
        """
        let killedRelay = """
        {"extensionConnected": true, "killSwitchAt": 1234}
        """

        #expect(!ChromuxLivePairing.resolve(
            psData: Data(observedPS.utf8),
            bridgeVersionData: Data(unrelatedServer.utf8),
            relayStatusData: Data("{\"extensionConnected\": true}".utf8)
        ).relayConnected)
        #expect(!ChromuxLivePairing.resolve(
            psData: Data(observedPS.utf8),
            bridgeVersionData: Data("{\"Browser\": \"chromux-live-bridge\"}".utf8),
            relayStatusData: Data(killedRelay.utf8)
        ).relayConnected)
    }
}

// MARK: - Chrome probe fallback (chromux optional)

private struct StubTabProbe: BrowserTabProbing {
    let result: [BrowserTabSnapshot]
    func tabs(preferredApplicationPIDs: Set<Int32>) async -> [BrowserTabSnapshot] { result }
}

/// chromux pairing is optional: with the relay connected the chromux listing
/// (capture-capable numeric tab ids) wins; without it the AppleScript
/// fallback still detects the Meet tab, and its prefixed ids are excluded
/// from capture attachment.
struct ChromeTabProbeFallbackTests {
    @Test
    func audioHelperPIDResolvesToItsTopLevelBrowserProcess() {
        let parents: [Int32: Int32] = [82_484: 677, 677: 1]
        #expect(ProcessAncestry.rootProcessID(startingAt: 82_484, parentOf: { parents[$0] }) == 677)
    }

    @Test
    func micOwningChromeInstanceWinsOverTheAmbiguousGenericAppleScriptTarget() {
        let personalMeet = BrowserTabSnapshot(
            id: "applescript:chrome:677:0",
            title: "Meet - cij-gwrn-stk",
            url: "https://meet.google.com/cij-gwrn-stk",
            isActive: true
        )
        let isolatedBrowserTab = BrowserTabSnapshot(
            id: "applescript:chrome:96040:0",
            title: "AI Crawler Arena",
            url: "https://airena.lol/battles/23"
        )

        let selected = ChromiumPIDTabSelection.select(
            preferredApplicationPIDs: [677],
            tabsByApplicationPID: [677: [personalMeet], 96_040: [isolatedBrowserTab]],
            genericTabs: [isolatedBrowserTab]
        )

        #expect(selected == [personalMeet])
    }

    @Test
    func chromuxListingWinsWhenAvailable() async {
        let chromuxTab = BrowserTabSnapshot(id: "412", title: "Meet", url: "https://meet.google.com/abc-defg-hij")
        let appleScriptTab = BrowserTabSnapshot(id: "applescript:chrome:0", title: "Meet", url: "https://meet.google.com/abc-defg-hij")
        let probe = ChromeTabProbe(
            primary: StubTabProbe(result: [chromuxTab]),
            fallback: StubTabProbe(result: [appleScriptTab])
        )
        #expect(await probe.tabs() == [chromuxTab])
    }

    @Test
    func aMeetingInAnotherPairedBrowserCannotMaskTheExpectedBrowserMeeting() async {
        let pairedDiaMeeting = BrowserTabSnapshot(id: "412", title: "Dia Meet", url: "https://meet.google.com/dia-room")
        let chromeMeeting = BrowserTabSnapshot(id: "applescript:chrome:0", title: "Chrome Meet", url: "https://meet.google.com/chrome-room")
        let probe = ChromeTabProbe(
            primary: StubTabProbe(result: [pairedDiaMeeting]),
            fallback: StubTabProbe(result: [chromeMeeting])
        )

        #expect(await probe.tabs() == [chromeMeeting])
    }

    @Test
    func aSharedStaleRoomInAnotherBrowserCannotRemoveTheNewActiveMeeting() async {
        let pairedOldMeeting = BrowserTabSnapshot(
            id: "412",
            title: "Paired old room",
            url: "https://meet.google.com/old-room"
        )
        let browserOldMeeting = BrowserTabSnapshot(
            id: "applescript:chrome:0",
            title: "Chrome old room",
            url: "https://meet.google.com/old-room"
        )
        let browserNewMeeting = BrowserTabSnapshot(
            id: "applescript:chrome:1",
            title: "Chrome new room",
            url: "https://meet.google.com/new-room",
            isActive: true
        )
        let probe = ChromeTabProbe(
            primary: StubTabProbe(result: [pairedOldMeeting]),
            fallback: StubTabProbe(result: [browserOldMeeting, browserNewMeeting])
        )

        let tabs = await probe.tabs()
        #expect(tabs.map(\.id) == ["412", "applescript:chrome:1"])
        let snapshot = MeetingDetectionSnapshot(
            micProcesses: [MicProcessSnapshot(bundleID: "com.google.Chrome.helper", isRunningInput: true)],
            zoomAppInMeeting: false,
            tabsByApp: [.chrome: tabs]
        )
        #expect(MeetingDetectionEngine.detect(snapshot).first?.meetingID == "meet:new-room")
    }

    @Test
    func nonMeetingChromuxTabsDoNotMaskTheBrowserMeetingFallback() async {
        let unrelatedChromuxTab = BrowserTabSnapshot(id: "412", title: "Docs", url: "https://docs.google.com/document/d/1")
        let browserMeeting = BrowserTabSnapshot(id: "applescript:chrome:0", title: "Meet", url: "https://meet.google.com/abc-defg-hij")
        let probe = ChromeTabProbe(
            primary: StubTabProbe(result: [unrelatedChromuxTab]),
            fallback: StubTabProbe(result: [browserMeeting])
        )

        #expect(await probe.tabs() == [browserMeeting])
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

    @Test
    func diaDetectionFallsBackWhenChromuxIsUnavailable() async {
        let fallbackTab = BrowserTabSnapshot(id: "applescript:dia:0", title: "Meet", url: "https://meet.google.com/abc-defg-hij")
        let probe = ChromeTabProbe(primary: StubTabProbe(result: []), fallback: StubTabProbe(result: [fallbackTab]))

        #expect(await probe.tabs() == [fallbackTab])
    }
}
