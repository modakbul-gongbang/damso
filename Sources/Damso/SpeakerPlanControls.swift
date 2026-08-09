import SwiftUI

/// Upper bound on the expected-speaker plan. Diarization pins to exactly this
/// many speakers, so an accidental huge value would force spurious clusters;
/// real meetings this tool records sit well under 20.
private let maxPlannedSpeakers = 20

enum SpeakerPlan {
    /// Starting value for a fresh recording plan: two speakers, the common
    /// case (1:1s, Google Meet 2-person calls), instead of leaving the
    /// unreliable auto-estimator to guess on the first try.
    static let defaultCount = 2

    /// The speaker count implied by a participant-name plan: the named people
    /// plus the recording user, since users list the *other* attendees (their
    /// own resolved speakers consistently read "나(...)" alongside the named
    /// participants). An empty plan implies Auto (0).
    static func derivedCount(forParticipants participants: [String]) -> Int {
        participants.isEmpty ? 0 : min(participants.count + 1, maxPlannedSpeakers)
    }

    /// Prefill-not-force: the stepper follows the participant list only while
    /// the user has not diverged from it - it still reads Auto, still holds
    /// the untouched starting default, or still holds the value derived from
    /// the previous list. A hand-adjusted count is never overwritten.
    static func prefilledCount(current: Int, oldParticipants: [String], newParticipants: [String]) -> Int {
        let previous = derivedCount(forParticipants: oldParticipants)
        guard current == 0 || current == defaultCount || current == previous else { return current }
        return derivedCount(forParticipants: newParticipants)
    }
}

/// Compact "expected speakers" stepper shown next to the Record button on both
/// the main window and the menu-bar card. A count of 0 reads as "Auto" and
/// leaves diarization to estimate the number; a positive value pins it.
struct SpeakerCountStepper: View {
    @Binding var count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(Loc.tr("Expected speakers"))
                .font(.damsoMonoCaption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Button {
                    if count > 0 { count -= 1 }
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(count <= 0)
                .accessibilityLabel(Loc.tr("Fewer speakers"))
                Text(count == 0 ? Loc.tr("Auto") : "\(count)")
                    .font(.system(.callout, design: .monospaced))
                    .frame(minWidth: 40)
                    .multilineTextAlignment(.center)
                Button {
                    if count < maxPlannedSpeakers { count += 1 }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(count >= maxPlannedSpeakers)
                .accessibilityLabel(Loc.tr("More speakers"))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("damso.speaker-count-stepper")
    }
}

/// Optional participant-name plan shown next to the Record controls. Typing
/// filters the existing People list into inline suggestions; a name with no
/// match can be added as-is (its profile is created later, when the speaker
/// is confirmed in review). Duplicates are rejected case-insensitively.
struct ParticipantPlanField: View {
    @Binding var participants: [String]
    var knownPeople: [String]

    @State private var draft = ""
    @FocusState private var isEditing: Bool

    private var available: [String] {
        knownPeople.filter { name in
            !participants.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    /// Known people matching the current draft, prefix matches first so the
    /// most likely completion sits directly under the cursor.
    private var suggestions: [String] {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let matches = available.filter { $0.range(of: query, options: [.caseInsensitive]) != nil }
        let ranked = matches.sorted { first, second in
            let firstPrefix = first.lowercased().hasPrefix(query.lowercased())
            let secondPrefix = second.lowercased().hasPrefix(query.lowercased())
            if firstPrefix != secondPrefix { return firstPrefix }
            return first.localizedStandardCompare(second) == .orderedAscending
        }
        return Array(ranked.prefix(5))
    }

    /// Whether the draft names someone who is not in People yet, so an
    /// explicit "add as new" row is offered under the suggestions.
    private var draftIsNewName: Bool {
        let query = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        return !knownPeople.contains { $0.caseInsensitiveCompare(query) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Loc.tr("Participants (optional)"))
                    .font(.damsoMonoCaption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if !available.isEmpty {
                    Menu {
                        ForEach(available, id: \.self) { name in
                            Button(name) { add(name) }
                        }
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel(Loc.tr("Add a known person"))
                }
            }
            if !participants.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(participants, id: \.self) { name in
                            HStack(spacing: 4) {
                                Text(name)
                                    .font(.damsoMonoCaption)
                                Button {
                                    remove(name)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption2)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Loc.tr("Remove participant"))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(DamsoTokens.hairline, in: Capsule())
                        }
                    }
                }
            }
            TextField(Loc.tr("Add a name"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.damsoMonoCaption)
                .focused($isEditing)
                .onSubmit {
                    // Enter completes to the top suggestion when one exists;
                    // otherwise the typed name is added as-is.
                    add(suggestions.first ?? draft)
                    draft = ""
                }
                .accessibilityIdentifier("damso.participant-plan-field")
            if isEditing, !suggestions.isEmpty || draftIsNewName {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(suggestions, id: \.self) { name in
                        Button {
                            add(name)
                            draft = ""
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(name)
                                    .font(.damsoMonoCaption)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                    if draftIsNewName {
                        Button {
                            add(draft)
                            draft = ""
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: Loc.tr("Add “%@” as a new name"), draft.trimmingCharacters(in: .whitespacesAndNewlines)))
                                    .font(.damsoMonoCaption)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .accessibilityIdentifier("damso.participant-plan-add-new")
                    }
                }
                .background(DamsoTokens.canvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(DamsoTokens.hairline)
                )
            }
        }
    }

    private func add(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !participants.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        participants.append(trimmed)
    }

    private func remove(_ name: String) {
        participants.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}
