import Foundation

/// Where a detected meeting is happening. The raw values are stable because
/// they are written into participants.json and recording metadata.
enum MeetingSourceApp: String, Codable, CaseIterable, Sendable {
    case zoomApp = "zoom-app"
    case chrome
    case dia
    case arc
    case safari

    /// Bundle identifier prefixes whose microphone use counts for this
    /// source. Compared case-insensitively.
    ///
    /// The Browser Company apps (Dia, Arc) hold the microphone in a shared
    /// ArcCore helper that reports `company.thebrowser.browser.helper`
    /// (measured live on Dia, 2026-07-17), so both carry that family prefix;
    /// when both browsers are installed the meeting-tab check and session
    /// merge resolve the ambiguity.
    var bundleIDPrefixes: [String] {
        switch self {
        case .zoomApp: ["us.zoom.xos"]
        case .chrome: ["com.google.chrome"]
        case .dia: ["company.thebrowser.dia", "company.thebrowser.browser"]
        case .arc: ["company.thebrowser.browser"]
        case .safari: ["com.apple.safari", "com.apple.webkit"]
        }
    }

    var displayName: String {
        switch self {
        case .zoomApp: "Zoom"
        case .chrome: "Chrome"
        case .dia: "Dia"
        case .arc: "Arc"
        case .safari: "Safari"
        }
    }

    /// Browsers whose tab check and participant capture run over the chromux
    /// extension channel (any Chromium browser the user pairs).
    var usesChromux: Bool {
        switch self {
        case .chrome, .dia, .arc: true
        case .zoomApp, .safari: false
        }
    }
}

/// Which meeting service the detected tab or app belongs to.
enum MeetingService: String, Codable, Sendable {
    case meet
    case zoom
}

/// One process currently capturing microphone input, as reported by the
/// CoreAudio process object list.
struct MicProcessSnapshot: Equatable, Sendable {
    var bundleID: String
    var isRunningInput: Bool
}

/// One open browser tab, as reported by chromux or AppleScript.
struct BrowserTabSnapshot: Equatable, Sendable {
    var id: String
    var title: String
    var url: String
}

/// Everything the detection decision needs, gathered by the runtime probes
/// and injectable as synthetic data in tests.
struct MeetingDetectionSnapshot: Equatable, Sendable {
    var micProcesses: [MicProcessSnapshot]
    /// True when the Zoom app shows an in-meeting signal (CptHost helper
    /// process running or a meeting window present). Filters out the
    /// microphone/speaker test and idle mic use.
    var zoomAppInMeeting: Bool
    var tabsByApp: [MeetingSourceApp: [BrowserTabSnapshot]]

    static let empty = MeetingDetectionSnapshot(micProcesses: [], zoomAppInMeeting: false, tabsByApp: [:])
}

/// A meeting judged to be in progress on one source.
struct DetectedMeetingSource: Equatable, Hashable, Sendable {
    var app: MeetingSourceApp
    var service: MeetingService
    /// Panel title hint: source name plus tab or window title.
    var titleHint: String
    /// Tab identifier for the browser tab the meeting was first seen in, so
    /// participant capture attaches to that exact tab.
    var tabID: String?
}

/// Pure meeting-or-not decision. No IO; the runtime feeds it real snapshots
/// and tests feed it synthetic ones.
enum MeetingDetectionEngine {
    /// Classifies a URL as a meeting URL. Meet: any meeting path on
    /// meet.google.com. Zoom web: zoom.us or *.zoom.us with a /j (join) or
    /// /wc (web client) path.
    static func meetingService(forURL rawURL: String) -> MeetingService? {
        guard let url = URL(string: rawURL), let host = url.host()?.lowercased() else { return nil }
        let path = url.path()
        if host == "meet.google.com" {
            // The Meet landing page ("/" or "/landing") is not a meeting.
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty, trimmed != "landing" else { return nil }
            return .meet
        }
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            guard path.hasPrefix("/j/") || path.hasPrefix("/wc/") || path == "/j" || path == "/wc" else { return nil }
            return .zoom
        }
        return nil
    }

    static func micInUse(by app: MeetingSourceApp, in snapshot: MeetingDetectionSnapshot) -> Bool {
        snapshot.micProcesses.contains { process in
            guard process.isRunningInput else { return false }
            let bundleID = process.bundleID.lowercased()
            return app.bundleIDPrefixes.contains { bundleID.hasPrefix($0) }
        }
    }

    /// The detection decision: a source counts as an active meeting only when
    /// its process uses the microphone AND its source-specific meeting signal
    /// holds. Plain mic use (voice memos, Discord, the Zoom audio test)
    /// produces no detection.
    static func detect(_ snapshot: MeetingDetectionSnapshot) -> [DetectedMeetingSource] {
        var detected: [DetectedMeetingSource] = []

        if micInUse(by: .zoomApp, in: snapshot), snapshot.zoomAppInMeeting {
            detected.append(DetectedMeetingSource(
                app: .zoomApp,
                service: .zoom,
                titleHint: MeetingSourceApp.zoomApp.displayName,
                tabID: nil
            ))
        }

        for app in [MeetingSourceApp.chrome, .dia, .arc, .safari] {
            guard micInUse(by: app, in: snapshot) else { continue }
            let tabs = snapshot.tabsByApp[app] ?? []
            // Multiple meeting tabs: only the first detected tab represents
            // the meeting (and is the one capture attaches to).
            guard let match = tabs.lazy.compactMap({ tab -> (BrowserTabSnapshot, MeetingService)? in
                guard let service = meetingService(forURL: tab.url) else { return nil }
                return (tab, service)
            }).first else { continue }
            let title = match.0.title.trimmingCharacters(in: .whitespacesAndNewlines)
            detected.append(DetectedMeetingSource(
                app: app,
                service: match.1,
                titleHint: title.isEmpty ? app.displayName : "\(app.displayName) · \(title)",
                tabID: match.0.id
            ))
        }

        return detected
    }
}
