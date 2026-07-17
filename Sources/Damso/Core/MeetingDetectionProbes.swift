import AppKit
import CoreAudio
import Foundation

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
    func tabs() async -> [BrowserTabSnapshot]
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
            snapshots.append(MicProcessSnapshot(bundleID: bundleID, isRunningInput: true))
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

/// Lists the user's real browser tabs through `chromux tabs --json` (live
/// extension pairing). Used for Chrome, and for Dia when the pairing probe
/// confirms it.
struct ChromuxTabProbe: BrowserTabProbing {
    var timeoutSeconds: TimeInterval = 5

    func tabs() async -> [BrowserTabSnapshot] {
        guard let data = await MeetingProbeSubprocess.run(
            arguments: ["chromux", "tabs", "--json"],
            timeoutSeconds: timeoutSeconds
        ) else { return [] }
        struct ChromuxTab: Decodable {
            var tabId: Int
            var title: String?
            var url: String?
        }
        guard let parsed = try? JSONDecoder().decode([ChromuxTab].self, from: data) else { return [] }
        return parsed.compactMap { tab in
            guard let url = tab.url, !url.isEmpty else { return nil }
            return BrowserTabSnapshot(id: String(tab.tabId), title: tab.title ?? "", url: url)
        }
    }
}

/// Lists Safari tabs via AppleScript (Automation permission). Only queried
/// while Safari is already running so the probe never launches Safari.
struct SafariTabProbe: BrowserTabProbing {
    var timeoutSeconds: TimeInterval = 5

    func tabs() async -> [BrowserTabSnapshot] {
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Safari" }
        guard running else { return [] }
        let script = """
        set out to ""
        tell application "Safari"
            repeat with w in windows
                repeat with t in tabs of w
                    set out to out & (URL of t) & "\\t" & (name of t) & linefeed
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
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let url = parts.first.map(String.init), url.hasPrefix("http") else { return nil }
            let title = parts.count > 1 ? String(parts[1]) : ""
            return BrowserTabSnapshot(id: "safari-\(index)", title: title, url: url)
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
