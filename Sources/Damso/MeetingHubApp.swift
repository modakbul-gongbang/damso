import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

/// App-lifetime objects shared by the main window and the resident detection
/// daemon: one workspace controller so detected recordings land in the same
/// store, state, and UI as manual ones.
@MainActor
final class DamsoRuntime: ObservableObject {
    let workspace: MeetingWorkspaceController
    let detection: MeetingDetectionCoordinator
    let externalSync: ExternalSyncController
    let notificationRouter: SummaryNotificationRouter

    init() {
        let workspace = MeetingWorkspaceController()
        self.workspace = workspace
        detection = MeetingDetectionCoordinator(workspace: workspace)
        externalSync = ExternalSyncController(workspace: workspace)
        notificationRouter = SummaryNotificationRouter()
        notificationRouter.workspace = workspace
        notificationRouter.attach()
        MeetingParticipantCaptureWiring.attach(to: detection)
        detection.startMonitoring()
        externalSync.start()
        // Verification-only simulation (V7): inject a synthetic detected
        // meeting for ~20s, then let it end so the prompt-dismiss grace can
        // be observed. Real probes are bypassed; the detection-enabled
        // setting still applies. Never active without the env flag.
        if ProcessInfo.processInfo.environment["MEETINGHUB_SIMULATE_DETECTION"] == "1" {
            let detection = detection
            Task { @MainActor in
                let source = DetectedMeetingSource(app: .chrome, service: .meet, titleHint: "Chrome · 시뮬레이션 미팅", tabID: "sim")
                try? await Task.sleep(for: .seconds(2))
                detection.simulatedSources = [source]
                try? await Task.sleep(for: .seconds(20))
                detection.simulatedSources = []
            }
        }
    }
}

@main
struct DamsoApp: App {
    @NSApplicationDelegateAdaptor(DamsoAppDelegate.self) private var appDelegate
    @StateObject private var loginItem = LoginItemController()
    @StateObject private var runtime = DamsoRuntime()

    init() {
        // Bundling support: `Damso --export-icon <path>` writes the
        // token-drawn app icon PNG for the local .app build and exits without
        // starting the UI or touching any meeting data.
        let arguments = CommandLine.arguments
        if let flagIndex = arguments.firstIndex(of: "--export-icon"), arguments.indices.contains(flagIndex + 1) {
            do {
                try AppIconAssets.exportPNG(to: URL(fileURLWithPath: arguments[flagIndex + 1]))
                exit(0)
            } catch {
                exit(1)
            }
        }
    }

    var body: some Scene {
        WindowGroup("Damso", id: "main") {
            DesignReviewWindow(workspace: runtime.workspace, externalSync: runtime.externalSync)
                .frame(minWidth: 1_120, minHeight: 720)
                .onAppear {
                    runtime.notificationRouter.openMainWindow = { appDelegate.openMainWindow() }
                }
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsRootView(sync: runtime.externalSync, loginItem: loginItem)
        }

        MenuBarExtra {
            MeetingMenuBarCard(
                workspace: runtime.workspace,
                detection: runtime.detection,
                panelModel: runtime.detection.panelModel,
                loginItem: loginItem,
                externalSync: runtime.externalSync,
                openMainWindow: { appDelegate.openMainWindow() }
            )
        } label: {
            AppIconAssets.menuBarImage()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Routes user-notification clicks back into the app. A summary-completion
/// notification carries the meeting stem in its payload; clicking it brings
/// the main window forward and selects that meeting (D-07, D-17). Foreground
/// posts still show as banners so a completion is visible while the app is
/// active.
@MainActor
final class SummaryNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    weak var workspace: MeetingWorkspaceController?
    var openMainWindow: (() -> Void)?

    /// The notification center only exists for a bundled .app; a bare
    /// `swift run` or test process must not touch it (same guard as
    /// SystemUserNotifier).
    func attach() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let stem = response.notification.request.content.userInfo[SummaryCalendarNotification.stemUserInfoKey] as? String
        await MainActor.run {
            openMainWindow?()
            if let stem {
                workspace?.select(stem: stem)
            }
        }
    }
}

@MainActor
final class DamsoAppDelegate: NSObject, NSApplicationDelegate {
    private let lifecycle = AppLifecycleCoordinator()
    private var hasPositionedInitialWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppIconAssets.applyDockIcon()
        // Reap any transcription orphaned by a previous crash/force-quit before
        // this instance starts its own processing, so the two never collide.
        ProcessingOrphanSweeper.sweepOrphans()
        lifecycle.didLaunch()
        DispatchQueue.main.async { [weak self] in
            self?.openMainWindow()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        lifecycle.didCloseLastWindow()
        return lifecycle.shouldTerminateAfterLastWindowClosed
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            openMainWindow()
        }
        return true
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        let visibleEnough = NSScreen.screens.contains { screen in
            let intersection = window.frame.intersection(screen.visibleFrame)
            return intersection.width >= 160 && intersection.height >= 120
        }
        let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.screens.first
        let visibleOnPrimary = primaryScreen.map { window.frame.intersection($0.visibleFrame).width >= 160 } ?? visibleEnough
        let shouldUsePrimaryScreen = !hasPositionedInitialWindow && !visibleOnPrimary
        if (!visibleEnough || shouldUsePrimaryScreen), let screen = primaryScreen {
            var frame = window.frame
            frame.size.width = min(frame.width, screen.visibleFrame.width)
            frame.size.height = min(frame.height, screen.visibleFrame.height)
            frame.origin.x = screen.visibleFrame.midX - frame.width / 2
            frame.origin.y = screen.visibleFrame.midY - frame.height / 2
            window.setFrame(frame, display: true)
        }
        hasPositionedInitialWindow = true
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Kill our own processing children before they reparent to launchd and
        // become orphans that outlive the app.
        ProcessingOrphanSweeper.terminateOwnChildren()
        lifecycle.willTerminate()
    }
}

@MainActor
final class AppLifecycleCoordinator {
    enum State: Equatable {
        case launching
        case running
        case windowClosedKeepRunning
        case terminating
    }

    private(set) var state: State = .launching

    var shouldTerminateAfterLastWindowClosed: Bool {
        false
    }

    func didLaunch() {
        state = .running
    }

    func didCloseLastWindow() {
        guard state != .terminating else { return }
        state = .windowClosedKeepRunning
    }

    func willTerminate() {
        state = .terminating
    }
}

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var configurationMessage: String?

    var isEnabled: Bool {
        status == .enabled
    }

    var canConfigure: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        refresh()
    }

    func setEnabledSafely(_ enabled: Bool) {
        guard canConfigure else {
            configurationMessage = "Launch at Login is available from a bundled macOS app."
            return
        }
        do {
            try setEnabled(enabled)
            configurationMessage = nil
        } catch {
            configurationMessage = error.localizedDescription
        }
    }
}
