import Foundation

enum MeetingDetailActions {
    static func applying(_ corrections: MeetingCorrections, to record: MeetingRecord) -> MeetingRecord {
        var updated = record
        updated.corrections = corrections
        return updated
    }

    /// Leaves captured source material and user corrections intact while making
    /// only the selected processing stage eligible for a deliberate retry.
    static func retry(_ stage: ProcessingStage, for record: MeetingRecord) -> MeetingRecord {
        var updated = record
        updated.stage = stage
        updated.lastErrorCode = nil
        updated.completedStages.removeAll { completedStage in completedStage == stage || completedStage.isTerminal }
        return updated
    }

    static func reprocessAll(for record: MeetingRecord) -> MeetingRecord {
        var updated = record
        updated.stage = .queued
        updated.completedStages = updated.completedStages.filter { $0 == .captured }
        updated.lastErrorCode = nil
        return updated
    }
}
