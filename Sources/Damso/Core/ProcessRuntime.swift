import Foundation

/// Shared environment for every helper process the app spawns.
///
/// A Finder- or Spotlight-launched app inherits only the minimal system PATH
/// (`/usr/bin:/bin:...`), which hides the user's Python (pyenv/homebrew) and
/// agent CLIs, so the same build behaves differently from `swift run` in a
/// terminal. Appending the well-known local tool directories keeps the
/// runtime deterministic regardless of how the app was launched. Nothing
/// else from the launch environment (API keys and so on) is forwarded.
enum ProcessRuntime {
    static func environment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let home = inherited["HOME"] ?? NSHomeDirectory()
        let inheritedEntries = (inherited["PATH"] ?? "").split(separator: ":").map(String.init)
        // The user-level tool directories go first so a pyenv/homebrew Python
        // wins over the system /usr/bin/python3 exactly as it does in the
        // user's terminal, then the inherited PATH, then the system fallback.
        let wellKnown = [
            "\(home)/.pyenv/shims",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/Library/pnpm",
        ]
        var entries: [String] = []
        for directory in wellKnown where FileManager.default.fileExists(atPath: directory) {
            entries.append(directory)
        }
        for directory in inheritedEntries where !entries.contains(directory) {
            entries.append(directory)
        }
        for fallback in ["/usr/bin", "/bin", "/usr/sbin", "/sbin"] where !entries.contains(fallback) {
            entries.append(fallback)
        }
        var environment = [
            "HOME": home,
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "PATH": entries.joined(separator: ":"),
        ]
        // The signed-in agent CLIs resolve their Keychain-backed session
        // through the macOS user identity; without USER/TMPDIR the claude CLI
        // exits non-zero. These identify the user context but carry no secret.
        environment["USER"] = inherited["USER"] ?? NSUserName()
        for name in ["LOGNAME", "SHELL", "TMPDIR", "__CF_USER_TEXT_ENCODING"] {
            if let value = inherited[name], !value.isEmpty {
                environment[name] = value
            }
        }
        return environment
    }
}
