import Foundation
import Testing
@testable import Damso

@Test
func ensureAvailableReturnsTrueImmediatelyWhenTheFileIsAlreadyLocal() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let localURL = directory.appendingPathComponent("audio.ogg")
    try Data("already here".utf8).write(to: localURL)

    // Even an unconfigured (local-mode) launcher should short-circuit on an
    // existing file without attempting anything remote.
    let fetcher = RemoteAudioFetcher(launcher: CommandLauncher(configuration: RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())))

    let available = await fetcher.ensureAvailable(localURL: localURL, remotePath: "/mini/Plaud/recordings/fixture/audio.ogg")

    #expect(available)
}

@Test
func ensureAvailableReturnsFalseInLocalModeWhenTheFileIsMissing() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let missingURL = directory.appendingPathComponent("audio.ogg")
    let fetcher = RemoteAudioFetcher(launcher: CommandLauncher(configuration: RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())))

    let available = await fetcher.ensureAvailable(localURL: missingURL, remotePath: "/mini/Plaud/recordings/fixture/audio.ogg")

    #expect(!available)
    #expect(!FileManager.default.fileExists(atPath: missingURL.path))
}

@Test
func ensureAvailableReturnsFalseWhenTheConfiguredRemoteHostIsUnreachable() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let missingURL = directory.appendingPathComponent("audio.ogg")
    let configuration = RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())
    configuration.configureRemote(host: "damso-test-host-that-does-not-exist.invalid", interpreterPath: "/opt/homebrew/bin/python3.12", storeRootPath: "/Volumes/DamsoMini/Application Support/Damso")
    let fetcher = RemoteAudioFetcher(launcher: CommandLauncher(configuration: configuration))

    let available = await fetcher.ensureAvailable(localURL: missingURL, remotePath: "/mini/Plaud/recordings/fixture/audio.ogg")

    #expect(!available)
    #expect(!FileManager.default.fileExists(atPath: missingURL.path))
}
