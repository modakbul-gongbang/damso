import Foundation

struct LocalIndexResult: Decodable, Equatable, Sendable {
    let ok: Bool
    let meetings: Int?
}

struct LocalIndexRebuildRequest: Encodable, Sendable {
    let operation = "rebuild-index"
    let storeRoot: String

    enum CodingKeys: String, CodingKey {
        case operation
        case storeRoot = "store_root"
    }
}

enum LocalIndexCommandError: Error, Equatable {
    case launchFailed
    case failed
    case invalidResponse
}

/// Rebuilds the derived SQLite search index from canonical files (D-06:
/// `/v1/rpc` over HTTP instead of a spawned/ssh'd `damso.index` process).
/// The index is a cache: a failed rebuild never blocks the pipeline and
/// never touches meeting files.
enum LocalIndexProcessRunner {
    static func rebuild(storeRoot: String, client: DamsoHTTPClient = DamsoHTTPClient()) throws -> LocalIndexResult {
        let data: Data
        do {
            data = try client.send(LocalIndexRebuildRequest(storeRoot: storeRoot))
        } catch {
            throw LocalIndexCommandError.launchFailed
        }
        guard let result = try? JSONDecoder().decode(LocalIndexResult.self, from: data), result.ok else {
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
