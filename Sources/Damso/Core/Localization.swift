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

    private static func loadCatalog() -> [String: [String: String]] {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "xcstrings"),
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
