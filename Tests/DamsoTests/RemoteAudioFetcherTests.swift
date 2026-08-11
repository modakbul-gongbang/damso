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

    // Even an unconfigured (local-mode) client should short-circuit on an
    // existing file without attempting any HTTP request.
    let fetcher = RemoteAudioFetcher(client: DamsoHTTPClient(configuration: ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())))

    let available = await fetcher.ensureAvailable(localURL: localURL, stem: "fixture", filename: "audio.ogg")

    #expect(available)
}

@Test
func ensureAvailableReturnsFalseWhenTheConfiguredRemoteHostIsUnreachable() async {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let missingURL = directory.appendingPathComponent("audio.ogg")
    let configuration = ServerConnectionConfiguration(preferences: InMemoryConfigurationPreferences(), tokenStore: InMemoryServerTokenStore())
    try? configuration.configureRemote(host: "damso-test-host-that-does-not-exist.invalid", port: 8787, token: "token", storeRootPath: "/Volumes/DamsoMini/Application Support/Damso")
    let fetcher = RemoteAudioFetcher(client: DamsoHTTPClient(configuration: configuration))

    let available = await fetcher.ensureAvailable(localURL: missingURL, stem: "fixture", filename: "audio.ogg")

    #expect(!available)
    #expect(!FileManager.default.fileExists(atPath: missingURL.path))
}
