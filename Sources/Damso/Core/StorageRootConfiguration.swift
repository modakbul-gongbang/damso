import Foundation

protocol ConfigurationPreferences: AnyObject {
    func string(forKey key: String) -> String?
    func setString(_ value: String?, forKey key: String)
}

extension UserDefaults: ConfigurationPreferences {
    func setString(_ value: String?, forKey key: String) {
        set(value, forKey: key)
    }
}

final class InMemoryConfigurationPreferences: ConfigurationPreferences {
    private var values: [String: String] = [:]

    func string(forKey key: String) -> String? {
        values[key]
    }

    func setString(_ value: String?, forKey key: String) {
        values[key] = value
    }
}

enum StorageRootConfigurationError: Error, Equatable, LocalizedError {
    case notALocalDirectory
    case unsafeRoot(StorageHealth)

    var errorDescription: String? {
        switch self {
        case .notALocalDirectory:
            "Choose an existing local folder for Damso data."
        case .unsafeRoot(let health):
            "The selected storage root is not safe: \(health)."
        }
    }
}

/// Owns only the selected root preference. It deliberately never relocates data
/// or falls back to a different root after the user has made a selection.
final class StorageRootConfiguration {
    static let selectedRootKey = "damso.selectedStorageRoot"

    private let preferences: ConfigurationPreferences
    private let defaultRoot: URL
    private let fileManager: FileManager
    private let minimumFreeBytes: Int64

    init(
        preferences: ConfigurationPreferences = UserDefaults.standard,
        defaultRoot: URL = MeetingStore.defaultRoot,
        fileManager: FileManager = .default,
        minimumFreeBytes: Int64 = 256 * 1_024 * 1_024
    ) {
        self.preferences = preferences
        self.defaultRoot = defaultRoot.standardizedFileURL
        self.fileManager = fileManager
        self.minimumFreeBytes = minimumFreeBytes
    }

    var hasExplicitSelection: Bool {
        preferences.string(forKey: Self.selectedRootKey) != nil
    }

    var rootURL: URL {
        guard let savedPath = preferences.string(forKey: Self.selectedRootKey), !savedPath.isEmpty else {
            return defaultRoot
        }
        return URL(fileURLWithPath: savedPath, isDirectory: true).standardizedFileURL
    }

    /// A missing explicitly selected folder is an error, not a prompt to create a
    /// new store elsewhere. The initial default root may be bootstrapped by the app.
    func health() -> StorageHealth {
        if hasExplicitSelection && !fileManager.fileExists(atPath: rootURL.path) {
            return .unavailable("The configured storage root is missing. Choose or restore that folder before continuing.")
        }
        return makeStore(rootURL).health()
    }

    /// Preflights and initializes an existing directory before persisting it.
    /// No data is copied, moved, or deleted during root selection.
    @discardableResult
    func select(root: URL) throws -> MeetingStore {
        let normalized = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard normalized.isFileURL,
              fileManager.fileExists(atPath: normalized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw StorageRootConfigurationError.notALocalDirectory
        }

        let store = makeStore(normalized)
        let rootHealth = store.health()
        guard case .ready = rootHealth else {
            throw StorageRootConfigurationError.unsafeRoot(rootHealth)
        }
        try store.bootstrap()
        preferences.setString(normalized.path, forKey: Self.selectedRootKey)
        return store
    }

    func clearSelection() {
        preferences.setString(nil, forKey: Self.selectedRootKey)
    }

    func makeStore() -> MeetingStore {
        makeStore(rootURL)
    }

    private func makeStore(_ root: URL) -> MeetingStore {
        MeetingStore(root: root, minimumFreeBytes: minimumFreeBytes, fileManager: fileManager)
    }
}
