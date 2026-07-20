import AppKit
import CoreAudio
import Darwin
import Foundation
import ScriptingBridge

enum ChromiumPIDTabSelection {
    static func select(
        preferredApplicationPIDs: Set<Int32>,
        tabsByApplicationPID: [Int32: [BrowserTabSnapshot]],
        genericTabs: [BrowserTabSnapshot]
    ) -> [BrowserTabSnapshot] {
        let targetedTabs = preferredApplicationPIDs.sorted().flatMap {
            tabsByApplicationPID[$0] ?? []
        }
        return targetedTabs.isEmpty ? genericTabs : targetedTabs
    }
}

/// Reports which processes are currently capturing microphone input.
protocol MicActivityProbing: Sendable {
    func micProcesses() -> [MicProcessSnapshot]
}

/// Reports whether the Zoom app shows an in-meeting signal.
protocol ZoomAppMeetingProbing: Sendable {
    func zoomAppInMeeting() -> Bool
}

/// Lists open tabs for one browser. Failures degrade to an empty list; tab
/// probes must never block or crash detection (guardrail G6).
protocol BrowserTabProbing: Sendable {
    func tabs(preferredApplicationPIDs: Set<Int32>) async -> [BrowserTabSnapshot]
}

extension BrowserTabProbing {
    func tabs() async -> [BrowserTabSnapshot] {
        await tabs(preferredApplicationPIDs: [])
    }
}

// MARK: - CoreAudio process-level microphone monitoring

/// Reads the CoreAudio process object list (macOS 14+ process property API)
/// and reports every process with running audio input.
struct CoreAudioMicActivityProbe: MicActivityProbing {
    func micProcesses() -> [MicProcessSnapshot] {
        var snapshots: [MicProcessSnapshot] = []
        for object in processObjects() {
            guard isRunningInput(object) else { continue }
            guard let bundleID = bundleID(object), !bundleID.isEmpty else { continue }
            let applicationProcessID = processID(object).flatMap(ProcessAncestry.rootProcessID)
            snapshots.append(MicProcessSnapshot(
                bundleID: bundleID,
                isRunningInput: true,
                applicationProcessID: applicationProcessID
            ))
        }
        return snapshots
    }

    private func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return []
        }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &dataSize, &objects) == noErr else {
            return []
        }
        return objects
    }

    private func bundleID(_ object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private func processID(_ object: AudioObjectID) -> Int32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        var value: pid_t = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value) == noErr,
              value > 0
        else { return nil }
        return value
    }

    private func isRunningInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &dataSize, &value) == noErr else {
            return false
        }
        return value != 0
    }
}

enum ProcessAncestry {
    static func rootProcessID(startingAt processID: Int32) -> Int32? {
        rootProcessID(startingAt: processID) { parentProcessID(of: $0) }
    }

    static func rootProcessID(
        startingAt processID: Int32,
        parentOf: (Int32) -> Int32?
    ) -> Int32? {
        guard processID > 0 else { return nil }
        var current = processID
        var visited: Set<Int32> = []
        while visited.insert(current).inserted,
              let parent = parentOf(current),
              parent > 1,
              parent != current {
            current = parent
        }
        return current
    }

    private static func parentProcessID(of processID: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.stride
        let result = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, $0, Int32(size))
        }
        guard result == size else { return nil }
        return Int32(info.pbi_ppid)
    }
}

// MARK: - Zoom app in-meeting signal

/// The Zoom audio test and an idle Zoom window also use the microphone; only
/// a running CptHost helper or an on-screen "Zoom Meeting" window marks an
/// actual meeting.
struct SystemZoomAppMeetingProbe: ZoomAppMeetingProbing {
    func zoomAppInMeeting() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "us.zoom.CptHost" }) {
            return true
        }
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return windows.contains { window in
            guard let owner = window[kCGWindowOwnerName as String] as? String, owner == "zoom.us" else { return false }
            let name = window[kCGWindowName as String] as? String ?? ""
            return name.contains("Zoom Meeting")
        }
    }
}

// MARK: - Browser tab probes

/// Passive chromux live-pairing status. `chromux ps --json` is the primary
/// source, with a loopback-only bridge check for an already-running live
/// relay whose daemon state file has gone missing. Neither path launches a
/// browser. This is the mandatory gate before `chromux tabs`, because that
/// command may launch the user's configured browser on a cold start.
enum ChromuxLivePairing {
    struct Status: Equatable {
        var relayConnected: Bool
    }

    static func status(timeoutSeconds: TimeInterval = 5) async -> Status {
        let psData = await MeetingProbeSubprocess.run(
            arguments: ["chromux", "ps", "--json"],
            timeoutSeconds: timeoutSeconds
        )
        let psStatus = parse(psData)
        if psStatus.relayConnected { return psStatus }

        guard let port = configuredLivePort() else { return psStatus }
        let versionData = await fetchLoopback(port: port, path: "/json/version")
        guard bridgeVersionIsValid(versionData) else { return psStatus }
        let relayStatusData = await fetchLoopback(port: port, path: "/relay/status")
        return resolve(
            psData: psData,
            bridgeVersionData: versionData,
            relayStatusData: relayStatusData
        )
    }

    static func parse(_ data: Data?) -> Status {
        guard let data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]],
              let live = profiles.first(where: { ($0["profile"] as? String) == "live" })
        else { return Status(relayConnected: false) }
        return Status(relayConnected: (live["extension"] as? String) == "connected")
    }

    /// Resolves the exact degraded runtime shape where `chromux ps` omits
    /// the live row even though the authenticated local bridge is healthy.
    /// Kept pure so the observed JSON can be locked down in a regression test.
    static func resolve(
        psData: Data?,
        bridgeVersionData: Data?,
        relayStatusData: Data?
    ) -> Status {
        let psStatus = parse(psData)
        if psStatus.relayConnected { return psStatus }
        guard bridgeVersionIsValid(bridgeVersionData),
              let relayStatusData,
              let relay = try? JSONSerialization.jsonObject(with: relayStatusData) as? [String: Any],
              relay["extensionConnected"] as? Bool == true
        else { return Status(relayConnected: false) }
        if let killSwitch = relay["killSwitchAt"], !(killSwitch is NSNull) {
            return Status(relayConnected: false)
        }
        return Status(relayConnected: true)
    }

    private static func bridgeVersionIsValid(_ data: Data?) -> Bool {
        guard let data,
              let version = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return version["Browser"] as? String == "chromux-live-bridge"
    }

    private static func configuredLivePort() -> Int? {
        let environment = ProcessInfo.processInfo.environment
        let root: URL
        if let override = environment["CHROMUX_HOME"], !override.isEmpty {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".chromux", isDirectory: true)
        }
        let configURL = root.appendingPathComponent("live.json")
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = config["port"] as? Int,
              (1...65_535).contains(port)
        else { return nil }
        return port
    }

    private static func fetchLoopback(port: Int, path: String) async -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return nil }
        return data
    }
}

/// Lists the user's real browser tabs through `chromux tabs --json` (live
/// extension pairing). Used for Chrome, and for Dia when the pairing probe
/// confirms it. Only queried while the live relay is already connected so
/// the probe never launches or focuses the user's Chrome (mirrors the
/// Safari probe's never-launch rule).
struct ChromuxTabProbe: BrowserTabProbing {
    var timeoutSeconds: TimeInterval = 5

    func tabs(preferredApplicationPIDs: Set<Int32>) async -> [BrowserTabSnapshot] {
        guard await ChromuxLivePairing.status(timeoutSeconds: timeoutSeconds).relayConnected else { return [] }
        guard let data = await MeetingProbeSubprocess.run(
            arguments: ["chromux", "tabs", "--json"],
            timeoutSeconds: timeoutSeconds
        ) else { return [] }
        struct ChromuxTab: Decodable {
            var tabId: Int
            var title: String?
            var url: String?
            var active: Bool?
        }
        guard let parsed = try? JSONDecoder().decode([ChromuxTab].self, from: data) else { return [] }
        return parsed.compactMap { tab in
            guard let url = tab.url, !url.isEmpty else { return nil }
            return BrowserTabSnapshot(
                id: String(tab.tabId),
                title: tab.title ?? "",
                url: url,
                isActive: tab.active ?? false
            )
        }
    }
}

/// Lists a scriptable Chromium browser's tabs via Apple Events (Automation
/// permission), so meeting detection works without chromux pairing. The
/// microphone-owning PID is targeted first to distinguish personal Chrome
/// from an isolated chromux Chrome; generic AppleScript remains the fallback.
/// Only queried while that browser is already running, so the probe never
/// launches it. Apple Event tab ids must never be used for capture.
struct ChromiumAppleScriptTabProbe: BrowserTabProbing {
    static let idPrefix = "applescript:"
    var applicationName = "Google Chrome"
    var bundleIdentifier = "com.google.Chrome"
    var browserID = "chrome"
    var timeoutSeconds: TimeInterval = 5

    func tabs(preferredApplicationPIDs: Set<Int32>) async -> [BrowserTabSnapshot] {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
        guard running else { return [] }
        var tabsByApplicationPID: [Int32: [BrowserTabSnapshot]] = [:]
        for processID in preferredApplicationPIDs {
            let tabs = await targetedTabs(processID: processID)
            if !tabs.isEmpty {
                tabsByApplicationPID[processID] = tabs
            }
        }
        let targeted = ChromiumPIDTabSelection.select(
            preferredApplicationPIDs: preferredApplicationPIDs,
            tabsByApplicationPID: tabsByApplicationPID,
            genericTabs: []
        )
        if !targeted.isEmpty { return targeted }

        let script = """
        set out to ""
        tell application "\(applicationName)"
            set windowIndex to 0
            repeat with w in windows
                set windowIndex to windowIndex + 1
                set activeID to id of active tab of w
                repeat with t in tabs of w
                    set isActive to (windowIndex is 1) and ((id of t) is activeID)
                    set out to out & (URL of t) & "\\t" & (title of t) & "\\t" & isActive & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        guard let data = await MeetingProbeSubprocess.run(
            arguments: ["osascript", "-e", script],
            timeoutSeconds: timeoutSeconds
        ), let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").enumerated().compactMap { index, line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard let url = parts.first.map(String.init), url.hasPrefix("http") else { return nil }
            let title = parts.count > 1 ? String(parts[1]) : ""
            let isActive = parts.count > 2 && parts[2] == "true"
            return BrowserTabSnapshot(
                id: "\(Self.idPrefix)\(browserID):\(index)",
                title: title,
                url: url,
                isActive: isActive
            )
        }
    }

    private func targetedTabs(processID: Int32) async -> [BrowserTabSnapshot] {
        let browserID = browserID
        let timeoutSeconds = timeoutSeconds
        return await Task.detached(priority: .utility) {
            Self.readTargetedTabs(
                processID: processID,
                browserID: browserID,
                timeoutSeconds: timeoutSeconds
            )
        }.value
    }

    private static func readTargetedTabs(
        processID: Int32,
        browserID: String,
        timeoutSeconds: TimeInterval
    ) -> [BrowserTabSnapshot] {
        guard let application = SBApplication(processIdentifier: processID), application.isRunning else { return [] }
        application.timeout = Int(timeoutSeconds * 60)
        guard let windows = application.value(forKey: "windows") as? [SBObject] else { return [] }
        var result: [BrowserTabSnapshot] = []
        for (windowIndex, window) in windows.enumerated() {
            guard let tabs = window.value(forKey: "tabs") as? [SBObject] else { continue }
            let activeTab = window.value(forKey: "activeTab") as? SBObject
            let activeID = activeTab?.value(forKey: "id") as? NSNumber
            let activeURL = activeTab?.value(forKey: "URL") as? String
            for (tabIndex, tab) in tabs.enumerated() {
                guard let url = tab.value(forKey: "URL") as? String, url.hasPrefix("http") else { continue }
                let title = tab.value(forKey: "title") as? String ?? ""
                let tabID = tab.value(forKey: "id") as? NSNumber
                let isActive = windowIndex == 0 && (
                    (tabID != nil && tabID == activeID) || (tabID == nil && url == activeURL)
                )
                result.append(BrowserTabSnapshot(
                    id: "\(idPrefix)\(browserID):\(processID):\(tabIndex)",
                    title: title,
                    url: url,
                    isActive: isActive
                ))
            }
        }
        return result
    }
}

typealias ChromeAppleScriptTabProbe = ChromiumAppleScriptTabProbe

/// Chromium tab listing with chromux as the primary channel and AppleScript
/// as the fallback: pairing stays optional for detection and upgrades the
/// result with capture-capable tab ids when connected.
struct ChromeTabProbe: BrowserTabProbing {
    var primary: any BrowserTabProbing = ChromuxTabProbe()
    var fallback: any BrowserTabProbing = ChromeAppleScriptTabProbe()

    func tabs(preferredApplicationPIDs: Set<Int32>) async -> [BrowserTabSnapshot] {
        let viaChromux = await primary.tabs(preferredApplicationPIDs: preferredApplicationPIDs)
        let viaBrowser = await fallback.tabs(preferredApplicationPIDs: preferredApplicationPIDs)

        // chromux can be paired to a different Chromium browser. Keep the
        // browser-specific AppleScript list, ordering, titles, and active-tab
        // state authoritative. Matching chromux rows only upgrade individual
        // ids for optional participant capture; they never remove another
        // meeting that exists in the expected browser.
        guard !viaBrowser.isEmpty else { return viaChromux }
        return viaBrowser.map { browserTab in
            guard let meetingID = MeetingDetectionEngine.meetingIdentity(forURL: browserTab.url),
                  let chromuxTab = viaChromux.first(where: {
                      MeetingDetectionEngine.meetingIdentity(forURL: $0.url) == meetingID
                  })
            else { return browserTab }
            var upgraded = browserTab
            upgraded.id = chromuxTab.id
            return upgraded
        }
    }
}

/// Lists Safari tabs via AppleScript (Automation permission). Only queried
/// while Safari is already running so the probe never launches Safari.
struct SafariTabProbe: BrowserTabProbing {
    var timeoutSeconds: TimeInterval = 5

    func tabs(preferredApplicationPIDs: Set<Int32>) async -> [BrowserTabSnapshot] {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Safari" }
        guard running else { return [] }
        let script = """
        set out to ""
        tell application "Safari"
            set windowIndex to 0
            repeat with w in windows
                set windowIndex to windowIndex + 1
                set activeURL to URL of current tab of w
                repeat with t in tabs of w
                    set isActive to (windowIndex is 1) and ((URL of t) is activeURL)
                    set out to out & (URL of t) & "\\t" & (name of t) & "\\t" & isActive & linefeed
                end repeat
            end repeat
        end tell
        return out
        """
        guard let data = await MeetingProbeSubprocess.run(
            arguments: ["osascript", "-e", script],
            timeoutSeconds: timeoutSeconds
        ), let output = String(data: data, encoding: .utf8) else { return [] }
        return output.split(separator: "\n").enumerated().compactMap { index, line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard let url = parts.first.map(String.init), url.hasPrefix("http") else { return nil }
            let title = parts.count > 1 ? String(parts[1]) : ""
            let isActive = parts.count > 2 && parts[2] == "true"
            return BrowserTabSnapshot(id: "safari-\(index)", title: title, url: url, isActive: isActive)
        }
    }
}

/// Bounded subprocess helper for detection probes: returns stdout on a zero
/// exit within the timeout, nil on any failure. Probes treat nil as "no
/// signal" so a broken CLI can never block detection or recording.
enum MeetingProbeSubprocess {
    static func run(
        arguments: [String],
        timeoutSeconds: TimeInterval,
        environmentOverrides: [String: String] = [:]
    ) async -> Data? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = arguments
                process.environment = ProcessRuntime.environment().merging(environmentOverrides) { _, override in override }
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = Pipe()
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let deadline = DispatchTime.now() + timeoutSeconds
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                    if process.isRunning {
                        process.terminate()
                    }
                }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }
}
