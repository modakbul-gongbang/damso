import Foundation
import Testing
@testable import Damso

@Test
func remoteExecutionConfigurationDefaultsToLocalWhenUnset() {
    let configuration = RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())
    #expect(configuration.mode == .local)
    #expect(configuration.remoteStoreRootPath == nil)
}

@Test
func remoteExecutionConfigurationSwitchesToRemoteOnlyOnceFullyConfigured() {
    let preferences = InMemoryConfigurationPreferences()
    let configuration = RemoteExecutionConfiguration(preferences: preferences)

    configuration.configureRemote(host: "mini", interpreterPath: "/opt/homebrew/bin/python3.12", storeRootPath: "/Volumes/DamsoMini/Application Support/Damso")

    #expect(configuration.mode == .remote(host: "mini", interpreterPath: "/opt/homebrew/bin/python3.12"))
    #expect(configuration.remoteStoreRootPath == "/Volumes/DamsoMini/Application Support/Damso")

    configuration.clearRemote()
    #expect(configuration.mode == .local)
    #expect(configuration.remoteStoreRootPath == nil)
}

@Test
func commandLauncherArgvIsUnchangedInLocalModeAndSshWrappedInRemoteMode() {
    let localLauncher = CommandLauncher(configuration: RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences()))
    #expect(localLauncher.argv(module: "damso.processing", moduleArguments: ["--request", "-"]) == ["python3", "-m", "damso.processing", "--request", "-"])

    let remotePreferences = InMemoryConfigurationPreferences()
    let remoteConfiguration = RemoteExecutionConfiguration(preferences: remotePreferences)
    remoteConfiguration.configureRemote(host: "mini", interpreterPath: "/opt/homebrew/bin/python3.12", storeRootPath: "/Volumes/DamsoMini/Application Support/Damso")
    let remoteLauncher = CommandLauncher(configuration: remoteConfiguration)

    #expect(remoteLauncher.argv(module: "damso.serve", moduleArguments: ["--store", "/Volumes/DamsoMini/Application Support/Damso"]) == [
        "ssh", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "mini", CommandLauncher.remotePathPrefix,
        "'/opt/homebrew/bin/python3.12'", "'-m'", "'damso.serve'", "'--store'", "'/Volumes/DamsoMini/Application Support/Damso'",
    ])
}

@Test
func shellQuoteEscapesEmbeddedSingleQuotesSoARemoteShellSeesOneArgument() {
    #expect(CommandLauncher.shellQuote("/Volumes/DamsoMini/Application Support/Damso") == "'/Volumes/DamsoMini/Application Support/Damso'")
    #expect(CommandLauncher.shellQuote("it's a test") == "'it'\\''s a test'")
}

@Test
func commandLauncherCapsResponseSizeRegardlessOfMode() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("huge-output")
    try """
    #!/bin/sh
    yes '0123456789' | head -c 200000
    """.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

    let launcher = CommandLauncher(configuration: RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences()))
    #expect(throws: CommandLauncherError.oversizedResponse) {
        try launcher.run(argv: [executable.path], maximumResponseBytes: 1_024)
    }
}

@Test
func protocolVersionIsInjectedAlongsideExistingRequestFields() throws {
    let input = Data(#"{"operation":"apply-resolutions","recording_directory":"/tmp/fixture"}"#.utf8)
    let versioned = try LocalProcessingProcessRunner.injectProtocolVersion(into: input)
    let fields = try #require(try JSONSerialization.jsonObject(with: versioned) as? [String: Any])
    #expect(fields["protocol_version"] as? Int == DamsoServeProtocol.version)
    #expect(fields["operation"] as? String == "apply-resolutions")
    #expect(fields["recording_directory"] as? String == "/tmp/fixture")
}

@Test
func remoteProtocolVersionMismatchDecodesToTheUpdateRequiredError() throws {
    let jsonRPCError = Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"unsupported protocol_version 1; server requires 2"}}"#.utf8)
    let output = CommandLauncherOutput(data: jsonRPCError, terminationStatus: 0)

    #expect(throws: LocalProcessingCommandError.remoteUpdateRequired) {
        _ = try LocalProcessingProcessRunner.decode(output)
    }
}

@Test
func remoteUnknownOperationErrorIsNotMisreadAsAnUpdateRequiredError() throws {
    let jsonRPCError = Data(#"{"jsonrpc":"2.0","id":7,"error":{"code":-32602,"message":"unknown operation"}}"#.utf8)
    let output = CommandLauncherOutput(data: jsonRPCError, terminationStatus: 0)

    #expect(throws: LocalProcessingCommandError.failed) {
        _ = try LocalProcessingProcessRunner.decode(output)
    }
}

@Test
func remoteOperationFailureDecodesTheSameBackendEnvelopeAsLocalDespiteAZeroExitCode() throws {
    // damso.serve is a persistent-server boundary: it reports operation
    // failure only in the JSON body, so exit code 0 here does not mean success.
    let body = Data(#"{"ok":false,"error":{"code":"invalid_local_processing_request","next_action":"Retry from the Meeting Hub canonical record."}}"#.utf8)
    let output = CommandLauncherOutput(data: body, terminationStatus: 0)

    #expect(throws: LocalProcessingCommandError.backend(code: "invalid_local_processing_request", nextAction: "Retry from the Meeting Hub canonical record.")) {
        _ = try LocalProcessingProcessRunner.decode(output)
    }
}

@Test
func remoteOperationSuccessDecodesIdenticallyToALocalResponse() throws {
    let body = Data(#"{"ok":true,"stage":"ready_for_summary","speaker_count":2}"#.utf8)
    let output = CommandLauncherOutput(data: body, terminationStatus: 0)

    let result = try LocalProcessingProcessRunner.decode(output)

    #expect(result.ok)
    #expect(result.stage == "ready_for_summary")
    #expect(result.speakerCount == 2)
}

@Test
func processOutputThrowsTransportFailedOnANonZeroExitInsteadOfMisreadingItAsGarbage() {
    // Before this check existed, a dropped/refused ssh connection (non-zero
    // exit, empty stdout) fell through to `.invalidResponse` - the same
    // error a live mini sending a malformed body would produce, making a
    // dead connection indistinguishable from a client-side decoding bug.
    let output = CommandLauncherOutput(data: Data(), terminationStatus: 255)

    #expect(throws: DamsoServeError.transportFailed(exitCode: 255)) {
        _ = try DamsoServeClient.processOutput(output)
    }
}

@Test
func processOutputStillRejectsAProtocolErrorOnAZeroExit() {
    let jsonRPCError = Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32001,"message":"unsupported protocol_version 1; server requires 2"}}"#.utf8)
    let output = CommandLauncherOutput(data: jsonRPCError, terminationStatus: 0)

    #expect(throws: DamsoServeError.remoteUpdateRequired) {
        _ = try DamsoServeClient.processOutput(output)
    }
}

@Test
func processOutputReturnsTheBodyUnchangedOnASuccessfulZeroExit() throws {
    let body = Data(#"{"ok":true}"#.utf8)
    let output = CommandLauncherOutput(data: body, terminationStatus: 0)

    #expect(try DamsoServeClient.processOutput(output) == body)
}

@Test
func remoteModeWithoutAConfiguredStoreRootFailsFastWithoutSpawningAnything() throws {
    let configuration = RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())
    configuration.configureRemote(host: "mini", interpreterPath: "/opt/homebrew/bin/python3.12", storeRootPath: "")
    let launcher = CommandLauncher(configuration: configuration)
    let request = LocalPersonEmailRequest(peoplesDirectory: "/tmp/Plaud/peoples", name: "Kim", email: "kim@example.com")

    #expect(throws: LocalProcessingCommandError.remoteMisconfigured) {
        _ = try LocalProcessingProcessRunner.setPersonEmail(request, launcher: launcher)
    }
}


@Test
func theRemotePathCarriesTheAgentCLIDirectorySoSummariesCanFindItOnTheServer() {
    // agent_boundary resolves the CLI with a bare shutil.which("claude"), and
    // the Claude Code installer puts it under ~/.local/bin. Without that entry
    // every summary on a two-machine setup failed as agent_cli_missing while
    // the CLI sat installed and signed in on the server.
    #expect(CommandLauncher.remotePathPrefix.contains("$HOME/.local/bin"))
    #expect(CommandLauncher.remotePathPrefix.contains("/opt/homebrew/bin"))

    // The prefix must reach the remote shell as shell text, not as a quoted
    // argument, or $HOME would arrive literal and resolve nothing.
    let configuration = RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())
    configuration.configureRemote(host: "mini", interpreterPath: "/opt/homebrew/bin/python3.12", storeRootPath: "/Volumes/DamsoMini/Application Support/Damso")
    let argv = CommandLauncher(configuration: configuration).argv(module: "damso.summary")
    #expect(argv.contains(CommandLauncher.remotePathPrefix))
    #expect(!argv.contains(CommandLauncher.shellQuote(CommandLauncher.remotePathPrefix)))
}
