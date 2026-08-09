import Foundation

struct LocalIndexResult: Decodable, Equatable, Sendable {
    let ok: Bool
    let meetings: Int?
}

enum LocalIndexCommandError: Error, Equatable {
    case launchFailed
    case failed
    case invalidResponse
}

/// Rebuilds the derived SQLite search index from canonical files by invoking
/// the fixed local Python module. The index is a cache: a failed rebuild
/// never blocks the pipeline and never touches meeting files.
enum LocalIndexProcessRunner {
    private static let maximumResponseBytes = 64 * 1_024

    static func rebuild(storeRoot: String, pythonExecutable: String = "python3", launcher: CommandLauncher = CommandLauncher()) throws -> LocalIndexResult {
        let argv: [String]
        switch launcher.configuration.mode {
        case .local:
            argv = [pythonExecutable, "-m", "damso.index", "--store", storeRoot]
        case .remote:
            argv = launcher.argv(module: "damso.index", moduleArguments: ["--store", storeRoot])
        }

        let output: CommandLauncherOutput
        do {
            output = try launcher.run(argv: argv, maximumResponseBytes: maximumResponseBytes)
        } catch CommandLauncherError.oversizedResponse {
            throw LocalIndexCommandError.failed
        } catch {
            throw LocalIndexCommandError.launchFailed
        }
        guard output.terminationStatus == 0 else {
            throw LocalIndexCommandError.failed
        }
        guard let result = try? JSONDecoder().decode(LocalIndexResult.self, from: output.data), result.ok else {
            throw LocalIndexCommandError.invalidResponse
        }
        return result
    }
}

/// Mirrors the Python duplicate-candidate tolerances so the meeting list can
/// flag suspected duplicates before pipeline entry without a database read.
/// Detection never merges or deletes anything.
enum DuplicateSuspects {
    static func stems(in records: [MeetingRecord]) -> Set<String> {
        var suspects: Set<String> = []
        for (index, first) in records.enumerated() {
            for second in records.dropFirst(index + 1) {
                guard first.source != second.source else { continue }
                let firstDuration = first.durationSeconds ?? 0
                let secondDuration = second.durationSeconds ?? 0
                let startDelta = abs(first.createdAt.timeIntervalSince(second.createdAt))
                let durationDelta = abs(firstDuration - secondDuration)
                let timeTolerance = max(90.0, min(firstDuration, secondDuration) * 0.25)
                let durationTolerance = max(90.0, max(firstDuration, secondDuration) * 0.25)
                if startDelta <= timeTolerance && durationDelta <= durationTolerance {
                    suspects.insert(first.stem)
                    suspects.insert(second.stem)
                }
            }
        }
        return suspects
    }
}
