import Foundation

/// User-selected defaults for the automatic summary step: which local agent
/// CLI runs it and which language the UI and generated artifacts use.
/// Preferences never fall back silently — a missing CLI surfaces as a
/// dependency state with a recovery action instead of switching agents.
enum AgentPreferences {
    static let agentKey = "damso.summaryAgent"
    static let languageKey = "damso.language"

    static func summaryAgent(_ defaults: UserDefaults = .standard) -> SummaryAgent {
        SummaryAgent(rawValue: defaults.string(forKey: agentKey) ?? "") ?? .claude
    }

    static func language(_ defaults: UserDefaults = .standard) -> SummaryLanguage {
        SummaryLanguage(rawValue: defaults.string(forKey: languageKey) ?? "") ?? .korean
    }

    static func setSummaryAgent(_ agent: SummaryAgent, _ defaults: UserDefaults = .standard) {
        defaults.set(agent.rawValue, forKey: agentKey)
    }

    static func setLanguage(_ language: SummaryLanguage, _ defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: languageKey)
    }

    /// Checks whether the agent CLI is reachable the same way the Python
    /// boundary resolves it (PATH lookup), without launching a model request.
    static func isAgentAvailable(_ agent: SummaryAgent) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", agent.executableName]
        process.environment = ProcessRuntime.environment()
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
