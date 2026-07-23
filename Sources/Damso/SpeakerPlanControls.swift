import SwiftUI

/// Upper bound on the expected-speaker plan. Diarization pins to exactly this
/// many speakers, so an accidental huge value would force spurious clusters;
/// real meetings this tool records sit well under 20.
private let maxPlannedSpeakers = 20

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

/// Optional participant-name plan for the main window. Names can be picked from
/// the existing People list (autocomplete-style menu) or typed freely; both
/// feed the transcription hint and speaker matching. Duplicates are rejected
/// case-insensitively.
struct ParticipantPlanField: View {
    @Binding var participants: [String]
    var knownPeople: [String]

    @State private var draft = ""

    private var available: [String] {
        knownPeople.filter { name in
            !participants.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
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
                .onSubmit { add(draft); draft = "" }
                .accessibilityIdentifier("damso.participant-plan-field")
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
