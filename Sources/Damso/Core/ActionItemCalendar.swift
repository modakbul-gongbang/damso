import EventKit
import Foundation

// MARK: Calendar boundary

enum CalendarAccessState: Equatable, Sendable {
    case notDetermined
    case denied
    case granted
}

/// One writable calendar as offered by the system. `account` is the owning
/// source (a Google account shows its account name here), which is how the
/// Settings picker helps the user find their Google calendar (D-05, D-10).
struct CalendarOption: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let account: String
}

enum CalendarWriteError: Error, Equatable {
    case accessDenied
    case calendarUnavailable
    case invalidDate
    case saveFailed(String)
}

/// The only boundary through which the app touches the system calendar. The
/// production implementation wraps EventKit; tests substitute a fake so the
/// add flow, dedup, and partial-failure behavior verify without EventKit.
@MainActor
protocol CalendarWriting: AnyObject {
    func accessState() -> CalendarAccessState
    func requestAccess() async -> Bool
    func writableCalendars() -> [CalendarOption]
    /// Creates one all-day event on `isoDate` (YYYY-MM-DD, local calendar day)
    /// and returns the created event's stable identifier.
    func addAllDayEvent(title: String, isoDate: String, notes: String, calendarID: String) throws -> String
}

@MainActor
final class EventKitCalendarWriter: CalendarWriting {
    private let store = EKEventStore()

    func accessState() -> CalendarAccessState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .writeOnly:
            return .granted
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }

    func requestAccess() async -> Bool {
        // The completion-handler API keeps the non-Sendable EKEventStore on
        // the main actor under strict concurrency.
        await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    func writableCalendars() -> [CalendarOption] {
        store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { CalendarOption(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title ?? "") }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    func addAllDayEvent(title: String, isoDate: String, notes: String, calendarID: String) throws -> String {
        guard accessState() == .granted else { throw CalendarWriteError.accessDenied }
        guard let calendar = store.calendar(withIdentifier: calendarID) else {
            throw CalendarWriteError.calendarUnavailable
        }
        guard let day = ActionItemCalendarPlanner.localDate(fromISO: isoDate) else {
            throw CalendarWriteError.invalidDate
        }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.notes = notes
        event.isAllDay = true
        event.startDate = day
        event.endDate = day
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarWriteError.saveFailed(error.localizedDescription)
        }
        return event.eventIdentifier ?? UUID().uuidString
    }
}

// MARK: Preferences

enum CalendarPreferences {
    static let targetCalendarKey = "calendar.targetCalendarID"
    static let notificationKey = "calendar.summaryNotificationEnabled"

    static func notificationEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: notificationKey) as? Bool ?? true
    }

    static func setNotificationEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: notificationKey)
    }

    static func storedTargetID(_ defaults: UserDefaults = .standard) -> String? {
        let raw = defaults.string(forKey: targetCalendarKey)
        return raw?.isEmpty == false ? raw : nil
    }

    static func setTargetID(_ id: String?, defaults: UserDefaults = .standard) {
        if let id, !id.isEmpty {
            defaults.set(id, forKey: targetCalendarKey)
        } else {
            defaults.removeObject(forKey: targetCalendarKey)
        }
    }

    /// The stored target only counts while it still exists: a calendar the
    /// user deleted from the system reverts the app to the unset state so the
    /// next add asks for a fresh choice (AC5).
    static func resolvedTargetID(defaults: UserDefaults = .standard, available: [CalendarOption]) -> String? {
        guard let stored = storedTargetID(defaults) else { return nil }
        return available.contains(where: { $0.id == stored }) ? stored : nil
    }
}

// MARK: Candidate selection

/// One action item eligible for calendar recording: it carries a concrete
/// resolved date. Identity is (task, dueDate) within one meeting (D-14).
struct CalendarCandidate: Identifiable, Equatable, Sendable {
    let task: String
    let owner: String?
    let dueDate: String

    var id: String { task + "\u{1F}" + dueDate }
}

enum ActionItemCalendarPlanner {
    /// Everything with a valid resolved date is a candidate: owner-agnostic
    /// and past dates included, because the product goal is a reference log,
    /// not a task manager (D-11, D-13).
    static func candidates(from summary: StructuredSummary?) -> [CalendarCandidate] {
        guard let actions = summary?.actions else { return [] }
        return actions.compactMap { action in
            guard let dueDate = action.dueDate, isValidISODate(dueDate) else { return nil }
            return CalendarCandidate(task: action.task, owner: action.owner, dueDate: dueDate)
        }
    }

    static func isValidISODate(_ value: String) -> Bool {
        value.count == 10 && localDate(fromISO: value) != nil
    }

    static func isAdded(_ candidate: CalendarCandidate, links: [CalendarEventLink]) -> Bool {
        links.contains { $0.task == candidate.task && $0.dueDate == candidate.dueDate }
    }

    /// Parses YYYY-MM-DD as the user's local calendar day.
    static func localDate(fromISO value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    /// Event notes carry the provenance the user asked for: which meeting the
    /// item came from and who owns it (D-09).
    static func eventNotes(meetingTitle: String, meetingDateText: String, owner: String?) -> String {
        var lines = [String(format: Loc.tr("From meeting: %@ (%@)"), meetingTitle, meetingDateText)]
        if let owner, !owner.isEmpty {
            lines.append(String(format: Loc.tr("Owner: %@"), owner))
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: Summary-completion notification

enum SummaryCalendarNotification {
    static let stemUserInfoKey = "damso.meeting.stem"

    /// Zero candidates never notify; the settings toggle silences the rest
    /// while the inline section stays available (D-21, AC7).
    static func shouldNotify(candidateCount: Int, enabled: Bool) -> Bool {
        enabled && candidateCount > 0
    }

    static func content(meetingTitle: String, candidateCount: Int) -> (title: String, body: String) {
        (
            title: String(format: Loc.tr("%@ summary is ready"), meetingTitle),
            body: String(format: Loc.tr("%d action items have dates and can be added to your calendar."), candidateCount)
        )
    }
}

// MARK: Add flow

/// Owns one meeting's add-to-calendar interaction: access state, the target
/// calendar, bulk add with per-item failure, and retry of failed items only.
/// Persistence goes through the injected closure so the workspace stays the
/// single owner of record mutation.
@MainActor
final class MeetingCalendarController: ObservableObject {
    @Published private(set) var accessState: CalendarAccessState = .notDetermined
    @Published private(set) var calendars: [CalendarOption] = []
    @Published private(set) var failures: [String: String] = [:]
    @Published private(set) var isAdding = false

    private let writer: any CalendarWriting
    private let defaults: UserDefaults

    init(writer: (any CalendarWriting)? = nil, defaults: UserDefaults = .standard) {
        self.writer = writer ?? EventKitCalendarWriter()
        self.defaults = defaults
        refresh()
    }

    func refresh() {
        accessState = writer.accessState()
        calendars = accessState == .granted ? writer.writableCalendars() : []
    }

    func requestAccessIfNeeded() async {
        guard accessState == .notDetermined else { return }
        _ = await writer.requestAccess()
        refresh()
    }

    var targetCalendarID: String? {
        CalendarPreferences.resolvedTargetID(defaults: defaults, available: calendars)
    }

    func setTargetCalendar(_ id: String) {
        CalendarPreferences.setTargetID(id, defaults: defaults)
        objectWillChange.send()
    }

    /// Adds the selected candidates as all-day events. Successes are handed
    /// to `persist` as links (partial success keeps them, AC8); failures stay
    /// in `failures` keyed by candidate id so retry targets only those items.
    func add(
        _ candidates: [CalendarCandidate],
        meetingTitle: String,
        meetingDateText: String,
        persist: ([CalendarEventLink]) -> Void
    ) {
        guard let calendarID = targetCalendarID else { return }
        isAdding = true
        defer { isAdding = false }
        var created: [CalendarEventLink] = []
        for candidate in candidates {
            do {
                let eventID = try writer.addAllDayEvent(
                    title: candidate.task,
                    isoDate: candidate.dueDate,
                    notes: ActionItemCalendarPlanner.eventNotes(
                        meetingTitle: meetingTitle,
                        meetingDateText: meetingDateText,
                        owner: candidate.owner
                    ),
                    calendarID: calendarID
                )
                created.append(CalendarEventLink(task: candidate.task, dueDate: candidate.dueDate, eventID: eventID))
                failures.removeValue(forKey: candidate.id)
            } catch {
                failures[candidate.id] = Loc.tr("Could not add this item. Retry below.")
            }
        }
        if !created.isEmpty {
            persist(created)
        }
    }
}
