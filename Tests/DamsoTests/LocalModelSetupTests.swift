import Foundation
import Testing
@testable import Damso

@Test
func modelSetupCommandHasOneFixedModuleBoundaryAndNoMeetingInput() {
    let root = URL(fileURLWithPath: "/tmp/damso-models", isDirectory: true)
    let command = LocalModelSetupCommand(modelRoot: root, install: true)

    #expect(command.arguments == [
        "python3",
        "-m",
        "damso.model_setup",
        "--install",
        "--model-root",
        root.path,
    ])
    #expect(!command.arguments.joined(separator: " ").localizedCaseInsensitiveContains("audio"))
    #expect(!command.arguments.joined(separator: " ").localizedCaseInsensitiveContains("transcript"))
}

@Test
func modelSetupStateExplainsAvailabilityWithoutDisclosingAPath() {
    #expect(LocalModelSetupState.unavailable("models_not_installed").title == Loc.tr("Local processing models are not installed"))
    #expect(LocalModelSetupState.ready.title == Loc.tr("Local processing models are ready"))
    for state in [LocalModelSetupState.unavailable("models_not_installed"), .ready, .checking, .installing, .failed("x")] {
        #expect(!state.title.contains("/"))
    }
}
