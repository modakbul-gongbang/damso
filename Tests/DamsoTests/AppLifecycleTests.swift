import Testing
@testable import Damso

@MainActor
@Test
func closingTheMainWindowKeepsTheMenuBarAppAliveUntilQuit() {
    let lifecycle = AppLifecycleCoordinator()
    lifecycle.didLaunch()
    lifecycle.didCloseLastWindow()

    #expect(lifecycle.state == .windowClosedKeepRunning)
    #expect(!lifecycle.shouldTerminateAfterLastWindowClosed)

    lifecycle.willTerminate()
    #expect(lifecycle.state == .terminating)
}
