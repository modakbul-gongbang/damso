import Foundation
import Testing
@testable import Damso

@Test
func syncIsANoOpAndReturnsFalseInLocalMode() async {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }
    let launcher = CommandLauncher(configuration: RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences()))
    let engine = CacheSyncEngine(launcher: launcher, cacheRoot: cacheRoot)

    let succeeded = await engine.sync()

    #expect(!succeeded)
    #expect(!FileManager.default.fileExists(atPath: cacheRoot.path))
}

@Test
func syncReturnsFalseWhenTheConfiguredRemoteHostIsUnreachable() async {
    let cacheRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: cacheRoot) }
    let configuration = RemoteExecutionConfiguration(preferences: InMemoryConfigurationPreferences())
    configuration.configureRemote(host: "damso-test-host-that-does-not-exist.invalid", interpreterPath: "/opt/homebrew/bin/python3.12", storeRootPath: "/Volumes/DamsoMini/Application Support/Damso")
    let engine = CacheSyncEngine(launcher: CommandLauncher(configuration: configuration), cacheRoot: cacheRoot)

    let succeeded = await engine.sync()

    #expect(!succeeded)
}

@Test
func includedFileNamesMatchR7ExactlyAndExcludeEverythingElseByOmission() {
    // The filter list itself is the contract (R7): this pins it against a
    // silent drift where a new artifact type is added to the pipeline but
    // never reaches the cache, or an excluded one sneaks back in.
    let expected: Set<String> = [
        "meeting.json", "transcript.raw.json", "transcript.json", "transcript.md", "transcript.cleaned.json",
        "identification.json", "summary.json", "speaker_hints.json", "resolutions.yaml", "hint.json",
        "participants.json", "profile.md", "voice.npy", ".deleted-people.json",
    ]
    #expect(Set(CacheSyncEngine.includedFileNames) == expected)
    let excludedByOmission: Set<String> = ["audio.ogg", "recording.mp3", "system-audio.m4a", "microphone.caf", "audio.wav", "speaker-embeddings.npz", "index.sqlite3"]
    #expect(Set(CacheSyncEngine.includedFileNames).isDisjoint(with: excludedByOmission))
}
