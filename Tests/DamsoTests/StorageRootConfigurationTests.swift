import Foundation
import Testing
@testable import Damso

private func isReady(_ health: StorageHealth) -> Bool {
    if case .ready = health { return true }
    return false
}

private func isUnavailable(_ health: StorageHealth) -> Bool {
    if case .unavailable = health { return true }
    return false
}

@Test
func selectedExistingRootIsBootstrappedAndPersistsAcrossConfigurationInstances() throws {
    let selectedRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: selectedRoot) }
    try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
    let preferences = InMemoryConfigurationPreferences()
    let configuration = StorageRootConfiguration(
        preferences: preferences,
        defaultRoot: FileManager.default.temporaryDirectory.appendingPathComponent("default", isDirectory: true),
        minimumFreeBytes: 0
    )

    let store = try configuration.select(root: selectedRoot)
    #expect(store.rootURL == selectedRoot.standardizedFileURL)
    #expect(configuration.hasExplicitSelection)
    #expect(configuration.rootURL == selectedRoot.standardizedFileURL)
    #expect(isReady(configuration.health()))
    #expect(FileManager.default.fileExists(atPath: selectedRoot.appendingPathComponent("Plaud/recordings").path))

    let restartedConfiguration = StorageRootConfiguration(
        preferences: preferences,
        defaultRoot: FileManager.default.temporaryDirectory.appendingPathComponent("other-default", isDirectory: true),
        minimumFreeBytes: 0
    )
    #expect(restartedConfiguration.rootURL == selectedRoot.standardizedFileURL)
}

@Test
func invalidOrMissingExplicitRootDoesNotFallbackToDefaultRoot() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let selectedRoot = temporary.appendingPathComponent("selected", isDirectory: true)
    let defaultRoot = temporary.appendingPathComponent("default", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try FileManager.default.createDirectory(at: selectedRoot, withIntermediateDirectories: true)
    let preferences = InMemoryConfigurationPreferences()
    let configuration = StorageRootConfiguration(preferences: preferences, defaultRoot: defaultRoot, minimumFreeBytes: 0)

    try configuration.select(root: selectedRoot)
    try FileManager.default.removeItem(at: selectedRoot)

    #expect(configuration.rootURL == selectedRoot.standardizedFileURL)
    #expect(isUnavailable(configuration.health()))
    #expect(!FileManager.default.fileExists(atPath: defaultRoot.path))
    #expect(throws: StorageRootConfigurationError.self) {
        try configuration.select(root: temporary.appendingPathComponent("does-not-exist", isDirectory: true))
    }
}

@Test
func plaudSessionUsesOnlyThePlatformSecretBoundary() throws {
    let backing = InMemorySecretStore()
    let secrets = PlaudSessionSecretStore(backing: backing)

    try secrets.save(Data("opaque-session".utf8))
    #expect(try secrets.load() == Data("opaque-session".utf8))
    #expect(try backing.read(service: DamsoSecrets.service, account: DamsoSecrets.plaudSessionAccount) == Data("opaque-session".utf8))
    try secrets.clear()
    #expect(try secrets.load() == nil)
}
