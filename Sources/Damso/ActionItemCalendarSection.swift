import AppKit
import SwiftUI

/// The action-item list inside a meeting summary. Structured items with a
/// resolved date become calendar candidates: a checkbox per item, one bulk
/// add button, an "Added" badge once recorded, and per-item failure with
/// failed-only retry (UX-01). Summaries without structured items (older
/// artifacts, user-corrected summaries) keep the plain list unchanged.
struct ActionItemCalendarSection: View {
    @ObservedObject var workspace: MeetingWorkspaceController
    let record: MeetingRecord
    let summary: StructuredSummary
    @StateObject private var controller = MeetingCalendarController()
    @State private var selection: Set<String> = []
    @State private var showCalendarPicker = false
    @State private var pickerCalendarID = ""

    private var candidates: [CalendarCandidate] {
        ActionItemCalendarPlanner.candidates(from: summary)
    }

    private var links: [CalendarEventLink] {
        record.calendarEventLinks ?? []
    }

    private var openCandidates: [CalendarCandidate] {
        candidates.filter { !ActionItemCalendarPlanner.isAdded($0, links: links) }
    }

    private var selectedCandidates: [CalendarCandidate] {
        openCandidates.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let actions = summary.actions, !actions.isEmpty {
                ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                    structuredRow(action)
                }
                if !candidates.isEmpty {
                    calendarFooter
                }
            } else {
                ForEach(summary.actionItems, id: \.self) { item in
                    Label(item, systemImage: "checkmark.circle")
                }
            }
        }
        .task(id: record.stem) {
            controller.refresh()
            selection = Set(openCandidates.map(\.id))
            showCalendarPicker = false
        }
    }

    private func structuredRow(_ action: SummaryActionItem) -> some View {
        let candidate: CalendarCandidate? = action.dueDate.flatMap { dueDate in
            ActionItemCalendarPlanner.isValidISODate(dueDate)
                ? CalendarCandidate(task: action.task, owner: action.owner, dueDate: dueDate)
                : nil
        }
        return VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let candidate {
                    if ActionItemCalendarPlanner.isAdded(candidate, links: links) {
                        BlockChip(title: Loc.tr("✓ Added"), block: DamsoTokens.blockLime)
                            .help(Loc.tr("This item is already on your calendar."))
                    } else {
                        Toggle("", isOn: selectionBinding(for: candidate))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                    }
                    Text(action.displayText)
                } else {
                    Label(action.displayText, systemImage: "checkmark.circle")
                }
            }
            if let candidate, let failure = controller.failures[candidate.id],
               !ActionItemCalendarPlanner.isAdded(candidate, links: links) {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.leading, 24)
            }
        }
    }

    private func selectionBinding(for candidate: CalendarCandidate) -> Binding<Bool> {
        Binding(
            get: { selection.contains(candidate.id) },
            set: { isOn in
                if isOn {
                    selection.insert(candidate.id)
                } else {
                    selection.remove(candidate.id)
                }
            }
        )
    }

    @ViewBuilder
    private var calendarFooter: some View {
        if controller.accessState == .denied {
            VStack(alignment: .leading, spacing: 6) {
                Text(Loc.tr("Calendar access is off, so action items cannot be added. Allow Calendar access for Damso in System Settings."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(Loc.tr("Open System Settings")) {
                    openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else if openCandidates.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if showCalendarPicker {
                    calendarPicker
                }
                Button(String(format: Loc.tr("Add %d selected to Calendar"), selectedCandidates.count), systemImage: "calendar.badge.plus") {
                    Task { await handleAdd() }
                }
                .buttonStyle(DamsoPillButtonStyle())
                .disabled(selectedCandidates.isEmpty || controller.isAdding)
            }
        }
    }

    @ViewBuilder
    private var calendarPicker: some View {
        if controller.calendars.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(Loc.tr("No writable calendar was found. Add your Google account in System Settings > Internet Accounts (with Calendars enabled) so events sync to Google Calendar."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(Loc.tr("Open Internet Accounts")) {
                    openSystemSettings("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        } else {
            HStack(spacing: 8) {
                Picker(Loc.tr("Choose a calendar"), selection: $pickerCalendarID) {
                    ForEach(controller.calendars) { calendar in
                        Text(calendarDisplayName(calendar)).tag(calendar.id)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Button(Loc.tr("Use this calendar")) {
                    controller.setTargetCalendar(pickerCalendarID)
                    showCalendarPicker = false
                    performAdd()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(pickerCalendarID.isEmpty)
            }
        }
    }

    private func calendarDisplayName(_ calendar: CalendarOption) -> String {
        calendar.account.isEmpty ? calendar.title : "\(calendar.title) — \(calendar.account)"
    }

    private func handleAdd() async {
        await controller.requestAccessIfNeeded()
        guard controller.accessState == .granted else { return }
        guard controller.targetCalendarID != nil else {
            // No usable target yet (never chosen, or the chosen calendar was
            // deleted): ask for a fresh choice before writing (AC5).
            pickerCalendarID = controller.calendars.first?.id ?? ""
            showCalendarPicker = true
            return
        }
        performAdd()
    }

    private func performAdd() {
        let stem = record.stem
        controller.add(
            selectedCandidates,
            meetingTitle: record.title,
            meetingDateText: record.createdAt.formatted(date: .abbreviated, time: .omitted)
        ) { created in
            workspace.appendCalendarLinks(created, stem: stem)
        }
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
