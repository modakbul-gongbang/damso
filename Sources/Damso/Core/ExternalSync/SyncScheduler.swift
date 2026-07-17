import Foundation

enum SyncAuthState: String, Codable, Sendable {
    case ready
    case requiresInteractiveLogin
}

struct SyncSchedulerState: Codable, Equatable, Sendable {
    var lastSuccessfulRun: Date?
    var nextAllowedRun: Date?
    var consecutiveFailures: Int
    var authState: SyncAuthState

    static let initial = SyncSchedulerState(lastSuccessfulRun: nil, nextAllowedRun: nil, consecutiveFailures: 0, authState: .ready)
}

enum SyncScheduleDecision: Equatable {
    case idle
    case waitForRecordingToStop
    case waitForReauthentication
    case backoff(until: Date)
    case run(catchUp: Bool)
}

enum SyncRunResult: Equatable {
    case success
    case transientFailure
    case authenticationExpired
}

/// Provider-neutral hourly schedule with exponential backoff and sleep/wake
/// catch-up, reused unchanged from the original Plaud scheduler logic.
struct SyncScheduler: Sendable {
    let interval: TimeInterval
    let initialBackoff: TimeInterval
    let maximumBackoff: TimeInterval
    let jitter: @Sendable (Int) -> TimeInterval

    init(
        interval: TimeInterval = 60 * 60,
        initialBackoff: TimeInterval = 60,
        maximumBackoff: TimeInterval = 30 * 60,
        jitter: @escaping @Sendable (Int) -> TimeInterval = { _ in 0 }
    ) {
        self.interval = interval
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
        self.jitter = jitter
    }

    func decision(for state: SyncSchedulerState, now: Date, recordingIsActive: Bool) -> SyncScheduleDecision {
        guard state.authState == .ready else { return .waitForReauthentication }
        if let nextAllowedRun = state.nextAllowedRun, nextAllowedRun > now {
            return .backoff(until: nextAllowedRun)
        }
        let isDue = state.lastSuccessfulRun.map { now.timeIntervalSince($0) >= interval } ?? true
        guard isDue else { return .idle }
        guard !recordingIsActive else { return .waitForRecordingToStop }
        let catchUp = state.lastSuccessfulRun.map { now.timeIntervalSince($0) > interval } ?? false
        return .run(catchUp: catchUp)
    }

    func applying(_ result: SyncRunResult, to state: SyncSchedulerState, at now: Date) -> SyncSchedulerState {
        var next = state
        switch result {
        case .success:
            next.lastSuccessfulRun = now
            next.nextAllowedRun = nil
            next.consecutiveFailures = 0
            next.authState = .ready
        case .transientFailure:
            next.consecutiveFailures += 1
            let exponent = max(0, next.consecutiveFailures - 1)
            let exponential = initialBackoff * pow(2, Double(exponent))
            let delay = min(maximumBackoff, exponential + max(0, jitter(next.consecutiveFailures)))
            next.nextAllowedRun = now.addingTimeInterval(delay)
        case .authenticationExpired:
            next.authState = .requiresInteractiveLogin
            next.nextAllowedRun = nil
        }
        return next
    }

    func applyingInteractiveLogin(to state: SyncSchedulerState) -> SyncSchedulerState {
        var next = state
        next.authState = .ready
        next.nextAllowedRun = nil
        next.consecutiveFailures = 0
        return next
    }
}

struct SyncImportOutcome: Codable, Equatable, Sendable {
    var remoteID: String
    var importedAt: Date?
    var errorCode: String?

    var isImported: Bool { importedAt != nil }
}

struct SyncImportIndex: Codable, Equatable, Sendable {
    private(set) var entries: [String: SyncImportOutcome]

    init(entries: [String: SyncImportOutcome] = [:]) {
        self.entries = entries
    }

    mutating func recordSuccess(remoteID: String, at date: Date = .now) {
        entries[remoteID] = SyncImportOutcome(remoteID: remoteID, importedAt: date, errorCode: nil)
    }

    mutating func recordFailure(remoteID: String, code: String) {
        let existing = entries[remoteID]
        entries[remoteID] = SyncImportOutcome(remoteID: remoteID, importedAt: existing?.importedAt, errorCode: code)
    }

    func needsImport(remoteID: String) -> Bool {
        !(entries[remoteID]?.isImported ?? false)
    }
}
