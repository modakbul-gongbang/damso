import Foundation

/// Reaps local processing and summary subprocesses so a killed or crashed app
/// can never leave a heavy transcription running that then collides with the
/// next launch (observed 2026-07-17: a force-quit left an orphaned
/// `damso.processing` re-transcribing in parallel with the new instance).
///
/// The match is deliberately narrow: only fixed Python module roots this app
/// spawns, plus subprocesses owned by those roots, and only when a root's
/// parent identifies it as ours - either the current app (graceful termination)
/// or launchd after the previous app died (`ppid == 1`). A live sibling
/// instance's process tree is never touched.
enum ProcessingOrphanSweeper {
    static let moduleMarkers = ["damso.processing", "damso.summary"]
    static let terminationGraceInterval: TimeInterval = 6

    struct ProcessTarget: Equatable {
        let pid: pid_t
        let parent: pid_t
        let command: String
        let identity: String
        let isRoot: Bool
    }

    private struct SnapshotEntry {
        let pid: pid_t
        let parent: pid_t
        let command: String
        let identity: String?
    }

    /// Kill leftovers reparented to launchd by a previous instance's death.
    static func sweepOrphans() {
        terminate(processingTargets(matchingParent: 1))
    }

    /// Kill this instance's own children as it exits, before they reparent.
    static func terminateOwnChildren() {
        terminate(processingTargets(matchingParent: getpid()))
    }

    /// Pure parser exposed for testing: given `ps` lines of "pid ppid command",
    /// return matching roots and every subprocess they own, leaf-first.
    static func matchingPIDs(psOutput: String, parent: pid_t) -> [pid_t] {
        let entries: [SnapshotEntry] = psOutput.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { return nil }
            return SnapshotEntry(pid: pid, parent: ppid, command: String(parts[2]), identity: nil)
        }
        return matchingEntries(entries, parent: parent).map(\.pid)
    }

    /// Parse the richer production snapshot. `lstart` and `command` together
    /// form the identity later revalidated before each signal. This prevents a
    /// PID recycled after the snapshot from receiving even the initial TERM.
    static func matchingTargets(psOutput: String, parent: pid_t) -> [ProcessTarget] {
        let entries: [SnapshotEntry] = psOutput.split(separator: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard parts.count == 8,
                  let pid = pid_t(parts[0]),
                  let ppid = pid_t(parts[1]) else { return nil }
            let command = String(parts[7]).trimmingCharacters(in: .whitespaces)
            let identity = normalizedIdentity(
                (parts[2...6].map(String.init) + [command]).joined(separator: " ")
            )
            return SnapshotEntry(pid: pid, parent: ppid, command: command, identity: identity)
        }
        return matchingEntries(entries, parent: parent).compactMap { entry in
            guard let identity = entry.identity else { return nil }
            return ProcessTarget(
                pid: entry.pid,
                parent: entry.parent,
                command: entry.command,
                identity: identity,
                isRoot: entry.parent == parent
                    && moduleMarkers.contains(where: entry.command.contains)
            )
        }
    }

    private static func matchingEntries(_ entries: [SnapshotEntry], parent: pid_t) -> [SnapshotEntry] {
        let roots = entries
            .filter { entry in
                entry.parent == parent
                    && entry.pid != getpid()
                    && moduleMarkers.contains(where: entry.command.contains)
            }
            .sorted { $0.pid < $1.pid }
        let children = Dictionary(grouping: entries, by: \SnapshotEntry.parent)
        var visited: Set<pid_t> = []
        var result: [SnapshotEntry] = []

        func appendTree(_ entry: SnapshotEntry) {
            guard visited.insert(entry.pid).inserted else { return }
            for child in (children[entry.pid] ?? []).sorted(by: { $0.pid < $1.pid }) {
                appendTree(child)
            }
            result.append(entry)
        }
        for root in roots {
            appendTree(root)
        }
        return result
    }

    private static func processingTargets(matchingParent parent: pid_t) -> [ProcessTarget] {
        guard let output = runPS() else { return [] }
        return matchingTargets(psOutput: output, parent: parent)
    }

    static func terminate(
        _ targets: [ProcessTarget],
        graceInterval: TimeInterval = terminationGraceInterval,
        sendSignal: (pid_t, Int32) -> Void = { pid, signal in _ = kill(pid, signal) },
        processGroupID: (pid_t) -> pid_t? = { pid in
            let group = getpgid(pid)
            return group < 0 ? nil : group
        },
        sendGroupSignal: (pid_t, Int32) -> Bool = { group, signal in
            kill(-group, signal) == 0
        },
        isAlive: (pid_t) -> Bool = { pid in kill(pid, 0) == 0 },
        processIdentity: (pid_t) -> String? = { pid in currentProcessIdentity(pid) },
        pause: (TimeInterval) -> Void = { interval in Thread.sleep(forTimeInterval: interval) }
    ) {
        guard !targets.isEmpty else { return }
        let signaledTargets = targets.filter { target in
            guard processIdentity(target.pid).map(normalizedIdentity) == target.identity else {
                return false
            }
            if target.isRoot, processGroupID(target.pid) == target.pid {
                // `getpgid` and identity are separate syscalls. Revalidate after
                // the group lookup so a recycled leader cannot redirect a
                // negative-PID signal to an unrelated process group.
                guard processIdentity(target.pid).map(normalizedIdentity) == target.identity else {
                    return false
                }
                if sendGroupSignal(target.pid, SIGTERM) {
                    return true
                }
                // A failed group signal falls back to the root itself, but only
                // after one more identity check for the same PID-reuse reason.
                guard processIdentity(target.pid).map(normalizedIdentity) == target.identity else {
                    return false
                }
            }
            sendSignal(target.pid, SIGTERM)
            return true
        }
        let deadline = Date().addingTimeInterval(max(0, graceInterval))
        var survivors = signaledTargets.filter { isAlive($0.pid) }
        while !survivors.isEmpty && Date() < deadline {
            pause(min(0.05, max(0, deadline.timeIntervalSinceNow)))
            survivors = survivors.filter { isAlive($0.pid) }
        }
        for target in survivors {
            guard processIdentity(target.pid).map(normalizedIdentity) == target.identity else {
                continue
            }
            if target.isRoot, processGroupID(target.pid) == target.pid {
                guard processIdentity(target.pid).map(normalizedIdentity) == target.identity else {
                    continue
                }
                if sendGroupSignal(target.pid, SIGKILL) {
                    continue
                }
                guard processIdentity(target.pid).map(normalizedIdentity) == target.identity else {
                    continue
                }
            }
            sendSignal(target.pid, SIGKILL)
        }
    }

    private static func currentProcessIdentity(_ pid: pid_t) -> String? {
        guard let output = runPS(arguments: ["-p", String(pid), "-o", "lstart=,command="]) else { return nil }
        let identity = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return identity.isEmpty ? nil : normalizedIdentity(identity)
    }

    private static func normalizedIdentity(_ identity: String) -> String {
        identity.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func runPS(arguments: [String] = ["-axo", "pid=,ppid=,lstart=,command="]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
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
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
