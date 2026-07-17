import Foundation
import Testing
@testable import Damso

// MARK: Fakes

/// Protocol-isolated calendar writer: proves the add flow, dedup, and
/// partial-failure behavior without touching EventKit (V4).
@MainActor
private final class FakeCalendarWriter: CalendarWriting {
    var access: CalendarAccessState = .granted
    var calendarsResult = [CalendarOption(id: "cal-1", title: "일정", account: "google@example.com")]
    var failingTasks: Set<String> = []
    private(set) var added: [(title: String, isoDate: String, notes: String, calendarID: String)] = []
    private var nextID = 0

    func accessState() -> CalendarAccessState { access }
    func requestAccess() async -> Bool { access == .granted }
    func writableCalendars() -> [CalendarOption] { calendarsResult }

    func addAllDayEvent(title: String, isoDate: String, notes: String, calendarID: String) throws -> String {
        if failingTasks.contains(title) { throw CalendarWriteError.saveFailed("synthetic failure") }
        added.append((title, isoDate, notes, calendarID))
        nextID += 1
        return "event-\(nextID)"
    }
}

private final class CalendarNoopCapture: RecordingCapture {
    func permissionState() async -> RecordingPermissionState { .ready }
    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles { fatalError("unused") }
    func stop() async throws -> CapturedAudioFiles { fatalError("unused") }
}

private func scratchDefaults() -> UserDefaults {
    let suite = "damso-calendar-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func summaryJSON(actionItems: String) -> String {
    """
    {"title":"주간 회의","role_hint":"","topic_summary":"topic","one_line_summary":"line",
     "key_points":["p"],"action_items":\(actionItems),"person_notes":[]}
    """
}

private func makeStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("damso-calendar-\(UUID().uuidString)", isDirectory: true)
    return (MeetingStore(root: root, minimumFreeBytes: 0), root)
}

private func writeSummaryArtifact(_ json: String, store: MeetingStore, root: URL, stem: String) throws {
    let dir = CanonicalStoreLayout(root: root).recordDirectory(stem: stem)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try json.write(to: dir.appendingPathComponent("summary.json"), atomically: true, encoding: .utf8)
}

// MARK: Artifact decoding (R2, AC2)

struct ActionItemArtifactDecodingTests {
    @Test
    func summaryWithDueDateYieldsStructuredActionsAndKeepsFlattenedText() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = summaryJSON(actionItems: """
        [{"task":"디자인 시안 전달","owner":"호연","due":"다음 주 금요일","due_date":"2026-07-24"},
         {"task":"백로그 정리","owner":null,"due":null,"due_date":null}]
        """)
        try writeSummaryArtifact(json, store: store, root: root, stem: "rec")

        let artifact = try #require(try store.storedSummaryArtifact(stem: "rec"))
        let actions = try #require(artifact.summary.actions)
        #expect(actions.count == 2)
        #expect(actions[0] == SummaryActionItem(task: "디자인 시안 전달", owner: "호연", due: "다음 주 금요일", dueDate: "2026-07-24"))
        #expect(actions[1].dueDate == nil)
        // The flattened display strings must not change shape.
        #expect(artifact.summary.actionItems[0] == "디자인 시안 전달 · Owner: 호연 · Due: 다음 주 금요일")
        #expect(artifact.summary.actionItems[1] == "백로그 정리")
        #expect(actions[0].displayText == artifact.summary.actionItems[0])
    }

    @Test
    func legacySummaryWithoutDueDateDecodesAndHasNoCandidates() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let json = summaryJSON(actionItems: """
        [{"task":"계약서 검토","owner":"김","due":"7월 말"}]
        """)
        try writeSummaryArtifact(json, store: store, root: root, stem: "legacy")

        let artifact = try #require(try store.storedSummaryArtifact(stem: "legacy"))
        #expect(artifact.summary.actionItems == ["계약서 검토 · Owner: 김 · Due: 7월 말"])
        #expect(artifact.summary.actions?.first?.dueDate == nil)
        #expect(ActionItemCalendarPlanner.candidates(from: artifact.summary).isEmpty)
    }

    @Test
    func structuredSummaryPersistedWithoutActionsFieldStillDecodes() throws {
        // A meeting.json written before this feature has no `actions` key.
        let legacy = """
        {"oneLine":"l","keyDiscussion":[],"actionItems":["do"],"roleHints":{},"topicSummary":"t"}
        """
        let decoded = try JSONDecoder().decode(StructuredSummary.self, from: Data(legacy.utf8))
        #expect(decoded.actions == nil)
        #expect(ActionItemCalendarPlanner.candidates(from: decoded).isEmpty)
    }
}

// MARK: Candidate selection (R3, AC3)

struct CalendarCandidateSelectionTests {
    @Test
    func candidatesIncludePastDatesAndOwnerlessItemsAndSkipInvalidDates() {
        let summary = StructuredSummary(
            oneLine: "l", keyDiscussion: [], actionItems: [], roleHints: [:], topicSummary: "t",
            actions: [
                SummaryActionItem(task: "지난 항목", owner: nil, due: "지난주", dueDate: "2020-01-02"),
                SummaryActionItem(task: "담당 없는 항목", owner: nil, due: "금요일", dueDate: "2026-07-24"),
                SummaryActionItem(task: "날짜 없는 항목", owner: "김", due: "언젠가", dueDate: nil),
                SummaryActionItem(task: "깨진 날짜", owner: nil, due: "곧", dueDate: "next friday"),
                SummaryActionItem(task: "존재하지 않는 날짜", owner: nil, due: "곧", dueDate: "2026-02-30"),
            ]
        )
        let candidates = ActionItemCalendarPlanner.candidates(from: summary)
        #expect(candidates.map(\.task) == ["지난 항목", "담당 없는 항목"])
    }

    @Test
    func addedStateMatchesOnTaskAndDueDate() {
        let candidate = CalendarCandidate(task: "do", owner: nil, dueDate: "2026-07-24")
        let links = [CalendarEventLink(task: "do", dueDate: "2026-07-24", eventID: "e1")]
        #expect(ActionItemCalendarPlanner.isAdded(candidate, links: links))
        // A re-summarized item with changed content is a fresh candidate (D-14).
        #expect(!ActionItemCalendarPlanner.isAdded(CalendarCandidate(task: "do", owner: nil, dueDate: "2026-07-25"), links: links))
        #expect(!ActionItemCalendarPlanner.isAdded(CalendarCandidate(task: "done", owner: nil, dueDate: "2026-07-24"), links: links))
    }

    @Test
    func isoDateValidationRejectsMalformedAndImpossibleDates() {
        #expect(ActionItemCalendarPlanner.isValidISODate("2026-07-24"))
        #expect(!ActionItemCalendarPlanner.isValidISODate("2026-7-24"))
        #expect(!ActionItemCalendarPlanner.isValidISODate("2026-02-30"))
        #expect(!ActionItemCalendarPlanner.isValidISODate("next friday"))
    }
}

// MARK: Add flow (R5, R8, AC4, AC8)

@MainActor
struct MeetingCalendarControllerTests {
    @Test
    func addCreatesAllDayEventsWithProvenanceNotesAndPersistsLinks() {
        let writer = FakeCalendarWriter()
        let defaults = scratchDefaults()
        CalendarPreferences.setTargetID("cal-1", defaults: defaults)
        let controller = MeetingCalendarController(writer: writer, defaults: defaults)
        let candidates = [
            CalendarCandidate(task: "디자인 시안 전달", owner: "호연", dueDate: "2026-07-24"),
            CalendarCandidate(task: "계약서 검토", owner: nil, dueDate: "2026-07-25"),
        ]
        var persisted: [CalendarEventLink] = []

        controller.add(candidates, meetingTitle: "주간 회의", meetingDateText: "2026. 7. 16.") { persisted.append(contentsOf: $0) }

        #expect(writer.added.count == 2)
        #expect(writer.added[0].title == "디자인 시안 전달")
        #expect(writer.added[0].isoDate == "2026-07-24")
        #expect(writer.added[0].calendarID == "cal-1")
        #expect(writer.added[0].notes.contains("주간 회의"))
        #expect(writer.added[0].notes.contains("호연"))
        #expect(persisted == [
            CalendarEventLink(task: "디자인 시안 전달", dueDate: "2026-07-24", eventID: "event-1"),
            CalendarEventLink(task: "계약서 검토", dueDate: "2026-07-25", eventID: "event-2"),
        ])
        #expect(controller.failures.isEmpty)
    }

    @Test
    func partialFailureKeepsSuccessesAndRetriesOnlyFailedItems() {
        let writer = FakeCalendarWriter()
        writer.failingTasks = ["계약서 검토"]
        let defaults = scratchDefaults()
        CalendarPreferences.setTargetID("cal-1", defaults: defaults)
        let controller = MeetingCalendarController(writer: writer, defaults: defaults)
        let ok = CalendarCandidate(task: "디자인 시안 전달", owner: nil, dueDate: "2026-07-24")
        let failing = CalendarCandidate(task: "계약서 검토", owner: nil, dueDate: "2026-07-25")
        var persisted: [CalendarEventLink] = []

        controller.add([ok, failing], meetingTitle: "회의", meetingDateText: "d") { persisted.append(contentsOf: $0) }

        #expect(persisted.map(\.task) == ["디자인 시안 전달"])
        #expect(controller.failures.keys.contains(failing.id))
        #expect(!controller.failures.keys.contains(ok.id))

        // Retry sends only the failed item and clears its failure on success.
        writer.failingTasks = []
        controller.add([failing], meetingTitle: "회의", meetingDateText: "d") { persisted.append(contentsOf: $0) }
        #expect(writer.added.map(\.title) == ["디자인 시안 전달", "계약서 검토"])
        #expect(persisted.map(\.task) == ["디자인 시안 전달", "계약서 검토"])
        #expect(controller.failures.isEmpty)
    }

    @Test
    func addWithoutResolvedTargetCalendarWritesNothing() {
        let writer = FakeCalendarWriter()
        let defaults = scratchDefaults()
        CalendarPreferences.setTargetID("deleted-calendar", defaults: defaults)
        let controller = MeetingCalendarController(writer: writer, defaults: defaults)
        var persisted: [CalendarEventLink] = []

        controller.add([CalendarCandidate(task: "do", owner: nil, dueDate: "2026-07-24")], meetingTitle: "m", meetingDateText: "d") { persisted.append(contentsOf: $0) }

        #expect(writer.added.isEmpty)
        #expect(persisted.isEmpty)
    }
}

// MARK: Added-state persistence across restart (R9, AC9)

@MainActor
struct CalendarLinkPersistenceTests {
    @Test
    func linksSurviveStoreReloadAndOldRecordsDecodeWithoutThem() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        var record = try store.createRecord(MeetingDraft(stem: "persist-rec", source: .local, title: "Synthetic"))
        try store.commit(record)

        record.calendarEventLinks = [CalendarEventLink(task: "do", dueDate: "2026-07-24", eventID: "e1")]
        try store.update(record)

        // A fresh store instance over the same root simulates an app restart.
        let reloaded = try MeetingStore(root: root, minimumFreeBytes: 0).load(stem: "persist-rec")
        #expect(reloaded.calendarEventLinks == [CalendarEventLink(task: "do", dueDate: "2026-07-24", eventID: "e1")])
    }

    @Test
    func appendCalendarLinksDeduplicatesByTaskAndDueDate() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let record = try store.createRecord(MeetingDraft(stem: "dedup-rec", source: .local, title: "Synthetic"))
        try store.commit(record)
        let workspace = MeetingWorkspaceController(store: store, capture: CalendarNoopCapture())

        let link = CalendarEventLink(task: "do", dueDate: "2026-07-24", eventID: "e1")
        workspace.appendCalendarLinks([link], stem: "dedup-rec")
        workspace.appendCalendarLinks([CalendarEventLink(task: "do", dueDate: "2026-07-24", eventID: "e2")], stem: "dedup-rec")
        workspace.appendCalendarLinks([CalendarEventLink(task: "do", dueDate: "2026-07-25", eventID: "e3")], stem: "dedup-rec")

        let stored = try store.load(stem: "dedup-rec")
        #expect(stored.calendarEventLinks == [
            link,
            CalendarEventLink(task: "do", dueDate: "2026-07-25", eventID: "e3"),
        ])
    }
}

// MARK: Notification conditions (R7, AC7)

struct SummaryCalendarNotificationTests {
    @Test
    func notifiesOnlyWithCandidatesAndEnabledToggle() {
        #expect(SummaryCalendarNotification.shouldNotify(candidateCount: 2, enabled: true))
        #expect(!SummaryCalendarNotification.shouldNotify(candidateCount: 0, enabled: true))
        #expect(!SummaryCalendarNotification.shouldNotify(candidateCount: 2, enabled: false))
        #expect(!SummaryCalendarNotification.shouldNotify(candidateCount: 0, enabled: false))
    }

    @Test
    func notificationDefaultsOnAndToggleTurnsItOff() {
        let defaults = scratchDefaults()
        #expect(CalendarPreferences.notificationEnabled(defaults))
        CalendarPreferences.setNotificationEnabled(false, defaults: defaults)
        #expect(!CalendarPreferences.notificationEnabled(defaults))
    }

    @Test
    func contentCarriesMeetingTitleAndCount() {
        let content = SummaryCalendarNotification.content(meetingTitle: "주간 회의", candidateCount: 2)
        #expect(content.title.contains("주간 회의"))
        #expect(content.body.contains("2"))
    }
}

// MARK: Settings state (R6, AC5)

@MainActor
struct CalendarSettingsStateTests {
    @Test
    func storedTargetRevertsToUnsetWhenCalendarDisappears() {
        let defaults = scratchDefaults()
        let available = [CalendarOption(id: "cal-1", title: "일정", account: "google@example.com")]
        #expect(CalendarPreferences.resolvedTargetID(defaults: defaults, available: available) == nil)

        CalendarPreferences.setTargetID("cal-1", defaults: defaults)
        #expect(CalendarPreferences.resolvedTargetID(defaults: defaults, available: available) == "cal-1")
        // The chosen calendar was deleted from the system.
        #expect(CalendarPreferences.resolvedTargetID(defaults: defaults, available: []) == nil)
    }

    @Test
    func deniedAccessExposesNoCalendars() {
        let writer = FakeCalendarWriter()
        writer.access = .denied
        let controller = MeetingCalendarController(writer: writer, defaults: scratchDefaults())
        controller.refresh()
        #expect(controller.accessState == .denied)
        #expect(controller.calendars.isEmpty)
        #expect(controller.targetCalendarID == nil)
    }
}

// MARK: Summary request date anchor (R1)

struct SummaryRequestMeetingDateTests {
    @Test
    func localMeetingDateFormatsAsISODay() {
        let date = Date(timeIntervalSince1970: 1_784_246_400) // 2026-07-16 UTC
        let formatted = LocalSummaryRequest.localMeetingDate(for: date)
        #expect(ActionItemCalendarPlanner.isValidISODate(formatted))
    }

    @Test
    func requestEncodesMeetingDateField() throws {
        let request = LocalSummaryRequest(recordingDirectory: "/tmp/x", agent: .claude, language: .korean, meetingDate: "2026-07-16")
        let data = try JSONEncoder().encode(request)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["meeting_date"] as? String == "2026-07-16")
    }
}
