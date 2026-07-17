import AppKit
import SwiftUI

/// Calendar pane: the one-time target calendar choice for action-item
/// recording plus the summary-completion notification toggle (UX-02).
/// Recording goes through macOS EventKit, so syncing to Google Calendar
/// requires the user's Google account calendar in macOS Internet Accounts.
struct CalendarSettingsView: View {
    @StateObject private var controller = MeetingCalendarController()
    @AppStorage(CalendarPreferences.notificationKey) private var notifyEnabled = true
    @AppStorage(CalendarPreferences.targetCalendarKey) private var targetCalendarID = ""

    var body: some View {
        SettingsGroup(title: Loc.tr("Action item calendar")) {
            switch controller.accessState {
            case .denied:
                SettingsRow(
                    title: Loc.tr("Calendar access"),
                    subtitle: Loc.tr("Calendar access is off, so action items cannot be added. Allow Calendar access for Damso in System Settings.")
                ) {
                    Button(Loc.tr("Open System Settings")) {
                        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                    }
                    .buttonStyle(.bordered)
                }
            case .notDetermined:
                SettingsRow(
                    title: Loc.tr("Calendar access"),
                    subtitle: Loc.tr("Allow Calendar access to record dated action items as all-day events.")
                ) {
                    Button(Loc.tr("Allow access")) {
                        Task { await controller.requestAccessIfNeeded() }
                    }
                    .buttonStyle(.bordered)
                }
            case .granted:
                if controller.calendars.isEmpty {
                    SettingsRow(
                        title: Loc.tr("Target calendar"),
                        subtitle: Loc.tr("No writable calendar was found. Add your Google account in System Settings > Internet Accounts (with Calendars enabled) so events sync to Google Calendar.")
                    ) {
                        Button(Loc.tr("Open Internet Accounts")) {
                            openSystemSettings("x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    SettingsRow(
                        title: Loc.tr("Target calendar"),
                        subtitle: Loc.tr("Dated action items are added to this calendar as all-day events. Pick your Google account's calendar so they appear in Google Calendar.")
                    ) {
                        Picker("", selection: $targetCalendarID) {
                            Text(Loc.tr("Not set")).tag("")
                            ForEach(controller.calendars) { calendar in
                                Text(calendarDisplayName(calendar)).tag(calendar.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            SettingsFootnote(text: Loc.tr("Damso only adds events. Edit or delete them in your calendar; re-summarizing never changes existing events."))
        }

        SettingsGroup(title: Loc.tr("Notifications")) {
            SettingsRow(
                title: Loc.tr("Notify when a summary has calendar candidates"),
                subtitle: Loc.tr("After a summary finishes with dated action items, a notification opens that meeting. The in-summary add section stays available either way.")
            ) {
                Toggle("", isOn: $notifyEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
        .onAppear {
            controller.refresh()
            // A stored calendar that no longer exists reverts to the unset
            // state so the next add asks for a fresh choice (AC5).
            if !targetCalendarID.isEmpty, controller.accessState == .granted,
               CalendarPreferences.resolvedTargetID(available: controller.calendars) == nil {
                targetCalendarID = ""
            }
        }
    }

    private func calendarDisplayName(_ calendar: CalendarOption) -> String {
        calendar.account.isEmpty ? calendar.title : "\(calendar.title) — \(calendar.account)"
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
