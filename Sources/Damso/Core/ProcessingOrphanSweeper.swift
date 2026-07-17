import Foundation

/// Reaps local processing and summary subprocesses so a killed or crashed app
/// can never leave a heavy transcription running that then collides with the
/// next launch (observed 2026-07-17: a force-quit left an orphaned
/// `damso.processing` re-transcribing in parallel with the new instance).
///
/// The match is deliberately narrow: only the fixed Python module invocations
/// this app spawns, and only processes whose parent identifies them as ours -
/// either the current app (graceful termination) or launchd after the previous
/// app died (`ppid == 1`). A live sibling instance's work is never touched.
enum ProcessingOrphanSweeper {
    static let moduleMarkers = ["damso.processing", "damso.summary"]

    /// Kill leftovers reparented to launchd by a previous instance's death.
    static func sweepOrphans() {
        terminate(processingPIDs(matchingParent: 1))
    }

    /// Kill this instance's own children as it exits, before they reparent.
    static func terminateOwnChildren() {
        terminate(processingPIDs(matchingParent: getpid()))
    }

    /// Pure parser exposed for testing: given `ps` lines of "pid ppid command",
    /// return the PIDs whose parent matches and whose command is one of ours.
    static func matchingPIDs(psOutput: String, parent: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        for rawLine in psOutput.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { continue }
            guard ppid == parent, pid != getpid() else { continue }
            let command = String(parts[2])
            guard moduleMarkers.contains(where: command.contains) else { continue }
            result.append(pid)
        }
        return result
    }

    private static func processingPIDs(matchingParent parent: pid_t) -> [pid_t] {
        guard let output = runPS() else { return [] }
        return matchingPIDs(psOutput: output, parent: parent)
    }

    private static func terminate(_ pids: [pid_t]) {
        for pid in pids {
            kill(pid, SIGTERM)
        }
    }

    private static func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
