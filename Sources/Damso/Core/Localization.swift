import Foundation

/// Resolves UI strings for the app's language setting (default Korean)
/// instead of the system locale, so the in-app language picker applies
/// immediately and identically for UI text and generated artifacts.
///
/// The String Catalog (Localizable.xcstrings) is the single authoring source.
/// SwiftPM copies the catalog into the resource bundle without compiling it,
/// so this loader reads the catalog JSON directly and caches one lookup
/// table per process.
enum Loc {
    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct StringUnit: Decodable {
                    let value: String
                }

                let stringUnit: StringUnit
            }

            let localizations: [String: Localization]?
        }

        let sourceLanguage: String
        let strings: [String: Entry]
    }

    private static let table: [String: [String: String]] = loadCatalog()

    static func tr(_ key: String) -> String {
        tr(key, language: AgentPreferences.language())
    }

    /// Explicit-language lookup: lets tests exercise the catalog without
    /// mutating the process-global language preference, which other code
    /// reads concurrently.
    static func tr(_ key: String, language: SummaryLanguage) -> String {
        if let value = table[key]?[language.rawValue], !value.isEmpty {
            return value
        }
        return key
    }

    /// Deliberately not `Bundle.module`. SwiftPM generates that accessor to
    /// check exactly two locations - the main bundle's *root* (never
    /// `Contents/Resources`, where a signed `.app` is the only place codesign
    /// permits it) and the absolute `.build` path of the machine that
    /// compiled the binary - and to `fatalError` when neither exists. An
    /// installed app was therefore reading its strings out of the developer's
    /// working copy, and crashed on launch the moment it ran anywhere else:
    /// copied to another Mac, or simply after `.build` was deleted.
    ///
    /// Resolving it here instead covers the installed-app layout, a plain
    /// `swift run`, and the test runner, and a miss degrades to the English
    /// keys (see `tr`) rather than taking the process down.
    private final class BundleFinder {}

    static func catalogURL() -> URL? {
        let fileName = "Localizable.xcstrings"
        let finder = Bundle(for: BundleFinder.self)
        let roots = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            finder.resourceURL,
            finder.bundleURL,
            finder.bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 }

        for root in roots {
            let inModuleBundle = root
                .appendingPathComponent("Damso_Damso.bundle", isDirectory: true)
                .appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: inModuleBundle.path) {
                return inModuleBundle
            }
            let alongside = root.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: alongside.path) {
                return alongside
            }
        }
        return nil
    }

    private static func loadCatalog() -> [String: [String: String]] {
        guard let url = catalogURL(),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else {
            return [:]
        }
        var result: [String: [String: String]] = [:]
        for (key, entry) in catalog.strings {
            var values: [String: String] = [:]
            for (language, localization) in entry.localizations ?? [:] {
                values[language] = localization.stringUnit.value
            }
            result[key] = values
        }
        return result
    }
}
