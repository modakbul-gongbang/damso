import AVFoundation
import AppKit
import SwiftUI

/// The main three-column workspace: sources sidebar, meeting/people list, and
/// a detail pane led by the pipeline stage indicator. Styling follows the
/// translated editorial tokens: monochrome frame, pastel block accents, mono
/// eyebrows, and pill-shaped primary actions.
struct DesignReviewWindow: View {
    @ObservedObject var workspace: MeetingWorkspaceController
    @ObservedObject var externalSync: ExternalSyncController
    @StateObject private var excerptPlayer = LocalExcerptPlayer()
    @StateObject private var audioPlayer = LocalAudioPlayer()
    @AppStorage(AgentPreferences.languageKey) private var languageSetting = SummaryLanguage.korean.rawValue
    @State private var libraryDestination: LibraryDestination = .meetingLog
    @State private var meetingDetailTab: MeetingDetailTab = .overview
    @State private var selectedPersonID: String?
    @State private var isHintEditorPresented = false
    @State private var isCorrectionPresented = false
    @State private var pickerSpeaker: SpeakerProposal?
    @State private var participantsText = ""
    @State private var topicText = ""
    @State private var domainTermsText = ""
    @State private var expectedSpeakerCount = 0
    @State private var correctedTitle = ""
    @State private var correctedSegments: [TranscriptSegment] = []
    @State private var correctedSummaryText = ""
    @State private var editedNotes: [String: String] = [:]
    @State private var personEmailDraft = ""
    @State private var personEmailStatus: String?
    @State private var mergeSourcePerson: LocalPersonProfile?
    @State private var showOriginalTranscript = false
    @State private var meetingSearchText = ""
    @State private var peopleSearchText = ""
    @FocusState private var isMeetingSearchFocused: Bool
    @FocusState private var isPeopleSearchFocused: Bool
    @State private var stageFilter: MeetingStageFilter = .all
    @State private var sourceFilter: MeetingSourceFilter = .all
    @State private var duplicatesOnly = false
    @State private var pendingDelete: MeetingRecord?
    /// Meetings the user hid from the "Needs your action" block this session;
    /// they drop to the list below instead of being deleted.
    @State private var dismissedActionStems: Set<String> = []

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } content: {
            libraryContent
        } detail: {
            libraryDetail
        }
        .navigationSplitViewStyle(.balanced)
        .tint(DamsoTokens.accent)
        .accessibilityLabel("Damso")
        .background {
            // Cmd+F focuses the search of whichever library is showing:
            // meetings in Meeting Log, people in People.
            Button("") {
                if libraryDestination == .people {
                    isPeopleSearchFocused = true
                } else {
                    isMeetingSearchFocused = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .task {
            workspace.refreshLibrary()
            workspace.resumeInterruptedImportedProcessing()
            workspace.resumeUnprocessedLocalRecordings()
            await workspace.resumeInterruptedSummaries()
        }
        .sheet(isPresented: $isHintEditorPresented) { hintsEditor }
        .sheet(isPresented: $isCorrectionPresented) { correctionEditor }
        .sheet(item: $mergeSourcePerson) { person in
            ProfileMergeSheet(
                current: person,
                others: workspace.people.filter { $0.id != person.id },
                onMerge: { primary, absorbed in
                    mergeSourcePerson = nil
                    Task {
                        if await workspace.mergeProfiles(primaryName: primary.name, absorbedName: absorbed.name) {
                            selectedPersonID = primary.id
                        }
                    }
                },
                onCancel: { mergeSourcePerson = nil }
            )
        }
        .sheet(item: $pickerSpeaker) { proposal in
            PersonPickerSheet(
                speaker: proposal.speaker,
                people: workspace.people,
                onSelect: { name, action in
                    pickerSpeaker = nil
                    Task { await workspace.applyResolution(speaker: proposal.speaker, action: action, personName: name, alias: proposal.suggestedParticipant) }
                },
                onCancel: { pickerSpeaker = nil }
            )
        }
        .alert(deleteConfirmationTitle, isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )) {
            Button(Loc.tr("Cancel"), role: .cancel) { pendingDelete = nil }
            Button(Loc.tr("Delete"), role: .destructive) {
                guard let record = pendingDelete else { return }
                pendingDelete = nil
                workspace.deleteMeeting(stem: record.stem)
            }
        } message: {
            Text(Loc.tr("The recording, transcript, and summary are removed from this Mac. This cannot be undone."))
        }
    }

    private var deleteConfirmationTitle: String {
        guard let record = pendingDelete else { return Loc.tr("Delete meeting") }
        return String(format: Loc.tr("Delete “%@”?"), meetingDisplayTitle(record))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List {
            Section {
                SidebarDestinationRow(title: Loc.tr("Meeting Log"), systemImage: "rectangle.stack", selected: libraryDestination == .meetingLog) {
                    libraryDestination = .meetingLog
                }
                SidebarDestinationRow(title: Loc.tr("People"), systemImage: "person.2", selected: libraryDestination == .people) {
                    libraryDestination = .people
                    if selectedPersonID == nil { selectedPersonID = workspace.people.first?.id }
                }
            }
            Section(Loc.tr("External Sync")) {
                ForEach(externalSync.providerStates) { provider in
                    ExternalSyncProviderRow(
                        provider: provider,
                        onSyncNow: { externalSync.syncNow(providerID: provider.id) },
                        onOpenSettings: { SettingsOpener.open() }
                    )
                }
            }
        }
        .navigationTitle("Damso")
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            RecordHeroButton(
                isRecording: workspace.isRecording,
                isPending: workspace.isCaptureStartPending
            ) {
                Task { await workspace.performPrimaryAction() }
            }
            .padding(12)
            .accessibilityLabel(workspace.isRecording ? Loc.tr("Stop recording") : Loc.tr("Record now"))
            .accessibilityIdentifier("damso.primary-record-action")
            .accessibilityHint(workspace.isRecording ? Loc.tr("Stops the current recording and starts local processing") : Loc.tr("Starts a recording without requiring hints"))
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if libraryDestination == .people {
            peopleList
        } else {
            meetingList
        }
    }

    @ViewBuilder
    private var libraryDetail: some View {
        if libraryDestination == .people {
            personDetail
        } else {
            detail
        }
    }

    // MARK: Meeting list

    /// Meetings the user still has to act on (confirm speakers, retry, or run
    /// the summary), kept above the completed ones. Ones the user hid this
    /// session drop out of here into the list below.
    private var actionNeededMeetings: [MeetingRecord] {
        filteredMeetings.filter { meetingActionPriority($0) <= 2 && !dismissedActionStems.contains($0.stem) }
    }

    private var restMeetings: [MeetingRecord] {
        filteredMeetings.filter { meetingActionPriority($0) > 2 || dismissedActionStems.contains($0.stem) }
    }

    /// The to-do block grows with its content up to a cap, then scrolls; when
    /// there is nothing completed below it, it fills the whole column instead.
    private var actionBlockHeight: CGFloat {
        guard !restMeetings.isEmpty else { return .greatestFiniteMagnitude }
        return min(CGFloat(actionNeededMeetings.count) * 66 + 8, 380)
    }

    private var meetingRecordingBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: workspace.isRecording ? "record.circle.fill" : "mic.circle")
                .font(.title2)
                .foregroundStyle(workspace.isRecording ? DamsoTokens.critical : DamsoTokens.ink)
            VStack(alignment: .leading, spacing: 3) {
                Text(stateMessage).font(.headline)
                Text(statusDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: DamsoTokens.compactRadius)
                .fill(workspace.isRecording ? DamsoTokens.blockPink.fillColor.opacity(0.6) : DamsoTokens.blockCream.fillColor.opacity(0.6))
        )
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    @ViewBuilder
    private func meetingRow(_ record: MeetingRecord, dismissable: Bool = false) -> some View {
        let isSelected = record.stem == workspace.selectedRecord?.stem
        HStack(spacing: 2) {
            Button {
                workspace.select(stem: record.stem)
            } label: {
                MeetingRow(
                    record: record,
                    selected: isSelected,
                    duplicateSuspect: workspace.duplicateStems.contains(record.stem)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if dismissable {
                Button {
                    dismissedActionStems.insert(record.stem)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Loc.tr("Hide from Needs your action"))
                .accessibilityLabel(Loc.tr("Hide from Needs your action"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DamsoTokens.compactRadius)
                .fill(isSelected ? DamsoTokens.accentFocusFill : Color.clear)
        )
        .contextMenu {
            if dismissable {
                Button(Loc.tr("Hide from Needs your action"), systemImage: "eye.slash") {
                    dismissedActionStems.insert(record.stem)
                }
            } else if dismissedActionStems.contains(record.stem) {
                Button(Loc.tr("Show in Needs your action"), systemImage: "eye") {
                    dismissedActionStems.remove(record.stem)
                }
            }
            Button(Loc.tr("Delete meeting"), systemImage: "trash", role: .destructive) {
                pendingDelete = record
            }
        }
    }

    private func meetingSectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.damsoEyebrow)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.damsoEyebrow)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// The stage/source/duplicate filter, composed as a dropdown inside the
    /// list container (moved out of the window toolbar) so it reads as part of
    /// the meeting log.
    private var meetingFilterMenu: some View {
        Menu {
            Picker(Loc.tr("Stage"), selection: $stageFilter) {
                ForEach(MeetingStageFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            Picker(Loc.tr("Source"), selection: $sourceFilter) {
                ForEach(MeetingSourceFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            Toggle(Loc.tr("Possible duplicates only"), isOn: $duplicatesOnly)
            if isMeetingFilterActive {
                Divider()
                Button(Loc.tr("Clear filters")) { clearMeetingFilters() }
            }
        } label: {
            Label(isMeetingFilterActive ? Loc.tr("Filtered") : Loc.tr("Filter"), systemImage: isMeetingFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .tint(isMeetingFilterActive ? DamsoTokens.accent : DamsoTokens.inkSecondary)
        .accessibilityLabel(Loc.tr("Filter meetings"))
    }

    private var meetingListHeader: some View {
        HStack(spacing: 8) {
            Text(Loc.tr("Meeting Log"))
                .font(.headline)
            Spacer()
            meetingFilterMenu
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }

    private var meetingList: some View {
        VStack(spacing: 0) {
            meetingRecordingBanner
            meetingListHeader
            if workspace.records.isEmpty {
                ContentUnavailableView(Loc.tr("No local meetings yet"), systemImage: "mic", description: Text(Loc.tr("Use Record now, or connect a service under External Sync.")))
                    .frame(maxHeight: .infinity)
            } else if filteredMeetings.isEmpty {
                ContentUnavailableView {
                    Label(Loc.tr("No meetings match the filters"), systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(Loc.tr("Adjust the search or filters to see more meetings."))
                } actions: {
                    Button(Loc.tr("Clear filters")) { clearMeetingFilters() }
                }
                .frame(maxHeight: .infinity)
            } else {
                if !actionNeededMeetings.isEmpty {
                    meetingSectionHeader(Loc.tr("Needs your action"), count: actionNeededMeetings.count)
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(actionNeededMeetings) { meetingRow($0, dismissable: true) }
                        }
                        .padding(.horizontal, 6)
                    }
                    // Bounded so a long to-do list never buries the completed
                    // meetings below; scrolls internally past the cap.
                    .frame(maxHeight: actionBlockHeight)
                    Divider().padding(.horizontal, 12)
                }
                if !restMeetings.isEmpty {
                    meetingSectionHeader(Loc.tr("Completed"), count: restMeetings.count)
                }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(restMeetings) { meetingRow($0) }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .navigationSplitViewColumnWidth(min: 290, ideal: 330, max: 380)
        .navigationTitle("")
        .searchable(text: $meetingSearchText, placement: .toolbar, prompt: Loc.tr("Search meetings"))
        .searchFocused($isMeetingSearchFocused)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(Loc.tr("Refresh library"), systemImage: "arrow.clockwise") {
                    workspace.refreshLibrary()
                }
                .accessibilityLabel(Loc.tr("Refresh local meeting library"))
            }
            ToolbarItem(placement: .automatic) {
                Button(Loc.tr("Meeting hints"), systemImage: "slider.horizontal.3") {
                    loadHintsForEditing()
                    isHintEditorPresented = true
                }
                .accessibilityHint(Loc.tr("Optional participants, topic, terms, and expected speaker count. Recording can start without them."))
            }
        }
    }

    private var filteredMeetings: [MeetingRecord] {
        let query = meetingSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matched = workspace.records.filter { record in
            guard stageFilter.matches(record.stage), sourceFilter.matches(record.source) else { return false }
            if duplicatesOnly, !workspace.duplicateStems.contains(record.stem) { return false }
            guard !query.isEmpty else { return true }
            if meetingDisplayTitle(record).localizedCaseInsensitiveContains(query) { return true }
            if participantNames(record).contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
            if let oneLine = (record.corrections?.summary ?? record.summary)?.oneLine,
               oneLine.localizedCaseInsensitiveContains(query) { return true }
            return false
        }
        // Surface meetings that need the user's attention first, keeping the
        // existing (newest-first) order within each priority band. Enumerated
        // index is the stable tiebreaker since sorted(by:) is not stable.
        return matched.enumerated()
            .sorted { lhs, rhs in
                let l = meetingActionPriority(lhs.element), r = meetingActionPriority(rhs.element)
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    /// Lower sorts higher: things the user must act on lead the list.
    private func meetingActionPriority(_ record: MeetingRecord) -> Int {
        switch record.stage {
        case .speakerReview:
            return record.resolutions.isEmpty ? 0 : (record.summary == nil ? 2 : 4)
        case .partial, .failed, .quarantined:
            return 1
        case .captured, .queued, .transcribing, .summarizing:
            return 3
        case .complete:
            return 4
        }
    }

    private var isMeetingFilterActive: Bool {
        stageFilter != .all || sourceFilter != .all || duplicatesOnly
            || !meetingSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func clearMeetingFilters() {
        meetingSearchText = ""
        stageFilter = .all
        sourceFilter = .all
        duplicatesOnly = false
    }

    // MARK: People list and profile

    /// Name and alias search so an absorbed name ("sori") still finds the
    /// profile that owns it now.
    private var filteredPeople: [LocalPersonProfile] {
        let query = peopleSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return workspace.people }
        return workspace.people.filter { person in
            person.name.localizedCaseInsensitiveContains(query)
                || person.aliases.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    private var peopleList: some View {
        List {
            if workspace.people.isEmpty {
                ContentUnavailableView(Loc.tr("No people yet"), systemImage: "person.2", description: Text(Loc.tr("People appear here after you confirm a speaker, or import a local peoples folder.")))
            } else if filteredPeople.isEmpty {
                ContentUnavailableView(Loc.tr("No people match the search"), systemImage: "magnifyingglass", description: Text(Loc.tr("Names and profile aliases are searched.")))
            } else {
                ForEach(filteredPeople) { person in
                    Button {
                        selectedPersonID = person.id
                    } label: {
                        HStack(spacing: 10) {
                            PersonBlockAvatar(name: person.name)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(person.name)
                                    .font(.headline)
                                Text(personSubtitle(person))
                                    .font(.damsoMonoCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selectedPersonID == person.id ? DamsoTokens.accent : Color.primary)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 290, ideal: 330, max: 380)
        .navigationTitle(Loc.tr("People"))
        .searchable(text: $peopleSearchText, placement: .toolbar, prompt: Loc.tr("Search people"))
        .searchFocused($isPeopleSearchFocused)
        .onAppear {
            if selectedPersonID == nil { selectedPersonID = workspace.people.first?.id }
        }
    }

    @ViewBuilder
    private var personDetail: some View {
        if let person = selectedPerson {
            ScrollView {
                VStack(alignment: .leading, spacing: DamsoTokens.spacingLG) {
                    HStack(spacing: 14) {
                        PersonBlockAvatar(name: person.name, large: true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(person.name)
                                .font(.damsoDisplay)
                            Text(person.hasVoiceProfile ? Loc.tr("Local voice profile ready") : Loc.tr("No saved voice profile"))
                                .font(.damsoMonoCaption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    EditorialSection(title: Loc.tr("Meeting history")) {
                        let meetings = meetings(for: person)
                        if meetings.isEmpty {
                            Text(Loc.tr("No confirmed meetings are linked to this person yet."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(meetings) { record in
                                    Button {
                                        workspace.select(stem: record.stem)
                                        libraryDestination = .meetingLog
                                    } label: {
                                        HStack(alignment: .top) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(meetingDisplayTitle(record))
                                                    .font(.body.weight(.medium))
                                                Text("\(record.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(speakingSummary(for: person, in: record))")
                                                    .font(.damsoMonoCaption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    EditorialSection(title: Loc.tr("Contact")) {
                        HStack(spacing: 8) {
                            Image(systemName: "envelope")
                                .foregroundStyle(.secondary)
                            TextField(Loc.tr("Email (optional)"), text: $personEmailDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 300)
                                .onSubmit { savePersonEmail(person) }
                            Button(Loc.tr("Save")) { savePersonEmail(person) }
                                .buttonStyle(DamsoPillButtonStyle(rank: .secondary))
                            if let status = personEmailStatus {
                                Text(status)
                                    .font(.damsoMonoCaption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    EditorialSection(title: Loc.tr("Aliases")) {
                        if person.aliases.isEmpty {
                            Text(Loc.tr("No aliases yet. Display names captured from meetings accumulate here after you confirm a speaker."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(person.aliases, id: \.self) { alias in
                                    HStack(spacing: 8) {
                                        BlockChip(title: alias, block: DamsoTokens.blockCream)
                                        Button {
                                            Task { await workspace.removePersonAlias(name: person.name, alias: alias) }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(String(format: Loc.tr("Remove alias %@"), alias))
                                    }
                                }
                                Text(Loc.tr("Aliases are used for search and candidate matching. Only the primary name is shown elsewhere."))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    EditorialSection(title: Loc.tr("Merge profiles")) {
                        VStack(alignment: .leading, spacing: 8) {
                            Button(Loc.tr("Merge with another profile..."), systemImage: "person.2.badge.gearshape") {
                                mergeSourcePerson = person
                            }
                            .buttonStyle(.bordered)
                            .disabled(workspace.people.count < 2)
                            Text(Loc.tr("Combines duplicate profiles: meeting history, voice profile, notes, and aliases move to the name you keep. The absorbed folder is archived first."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    EditorialSection(title: Loc.tr("Profile notes")) {
                        if let notes = workspace.profileNotes(for: person) {
                            Text(notes)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        } else {
                            Text(Loc.tr("Accepted meeting notes about this person will appear here."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle(Loc.tr("Person detail"))
            .task(id: person.id) {
                personEmailDraft = workspace.profileEmail(for: person) ?? ""
                personEmailStatus = nil
            }
        } else {
            ContentUnavailableView(Loc.tr("Select a person"), systemImage: "person.2", description: Text(Loc.tr("People confirmed from speaker review appear here.")))
                .navigationTitle(Loc.tr("Person detail"))
        }
    }

    private func savePersonEmail(_ person: LocalPersonProfile) {
        let email = personEmailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        personEmailStatus = nil
        Task {
            let saved = await workspace.setPersonEmail(name: person.name, email: email)
            personEmailStatus = saved ? Loc.tr("Saved") : nil
        }
    }

    private var stateMessage: String {
        switch workspace.state {
        case .ready: Loc.tr("Ready to capture")
        case .checkingPermissions: Loc.tr("Waiting for recording permissions")
        case .recording: Loc.tr("Recording in progress")
        case .processing: Loc.tr("Processing locally")
        case .speakerReview(let count): String(format: Loc.tr("%d speakers need review"), count)
        case .failed: Loc.tr("Recording needs attention")
        }
    }

    private var statusDetail: String {
        switch workspace.state {
        case .checkingPermissions:
            Loc.tr("Approve the macOS Microphone and Screen Recording prompts. Capture starts automatically after approval.")
        case .recording:
            Loc.tr("Microphone and system audio are being kept locally.")
        case .processing:
            Loc.tr("Local processing is running. The next stage starts automatically.")
        case .speakerReview:
            Loc.tr("Confirm the speaker cards. The summary and title are created automatically afterwards.")
        case .failed:
            workspace.recoveryAction ?? Loc.tr("Review the local status and retry.")
        case .ready:
            Loc.tr("Start now. Add speaker or topic hints whenever you need them.")
        }
    }

    // MARK: Editors

    private var hintsEditor: some View {
        NavigationStack {
            Form {
                Section(Loc.tr("Optional context")) {
                    TextField(Loc.tr("Participants, separated by commas"), text: $participantsText)
                    TextField(Loc.tr("Topic"), text: $topicText)
                    TextField(Loc.tr("Domain terms, separated by commas"), text: $domainTermsText)
                    Stepper(String(format: Loc.tr("Expected speakers: %@"), expectedSpeakerCount == 0 ? Loc.tr("Not set") : String(expectedSpeakerCount)), value: $expectedSpeakerCount, in: 0...12)
                }
                Text(Loc.tr("These hints are optional. Record now starts capture immediately whether or not you add them."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle(Loc.tr("Meeting hints"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("Cancel")) { isHintEditorPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc.tr("Save")) { saveHints() }
                }
            }
        }
        .frame(width: 520, height: 330)
    }

    private var correctionEditor: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DamsoTokens.spacingLG) {
                    Text(Loc.tr("Corrections are kept separate from original local processing output, so retry and reprocessing remain auditable."))
                        .font(.damsoMonoCaption)
                        .foregroundStyle(.secondary)

                    EditorialSection(title: Loc.tr("Meeting title")) {
                        TextField(Loc.tr("Title"), text: $correctedTitle)
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                            .padding(12)
                            .background(editorFieldBackground)
                    }

                    EditorialSection(title: Loc.tr("Summary correction")) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextEditor(text: $correctedSummaryText)
                                .font(.body)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 84)
                                .padding(8)
                                .background(editorFieldBackground)
                            Text(Loc.tr("Leave this blank to keep an unavailable summary unavailable."))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    EditorialSection(title: Loc.tr("Transcript corrections")) {
                        if correctedSegments.isEmpty {
                            Text(Loc.tr("No local transcript is available yet."))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(correctedSegments.enumerated()), id: \.offset) { index, segment in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack(spacing: 8) {
                                            BlockChip(title: correctionSpeakerName(segment.speaker), block: DamsoTokens.blockLilac)
                                            Text(timestamp(segment.startSeconds))
                                                .font(.damsoMonoCaption)
                                                .foregroundStyle(.secondary)
                                        }
                                        TextEditor(text: Binding(
                                            get: { correctedSegments[index].text },
                                            set: { correctedSegments[index].text = $0 }
                                        ))
                                        .font(.body)
                                        .scrollContentBackground(.hidden)
                                        .frame(minHeight: 52)
                                        .padding(6)
                                        .background(editorFieldBackground)
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: DamsoTokens.compactRadius)
                                            .fill(DamsoTokens.blockCream.fillColor.opacity(0.35))
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle(Loc.tr("Edit meeting"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("Cancel")) { isCorrectionPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Loc.tr("Save")) {
                        workspace.saveCorrections(
                            title: correctedTitle,
                            transcript: correctedSegments.isEmpty ? nil : correctedSegments,
                            summary: correctedSummary()
                        )
                        isCorrectionPresented = false
                    }
                }
            }
        }
        .frame(width: 680, height: 760)
    }

    private var editorFieldBackground: some View {
        RoundedRectangle(cornerRadius: DamsoTokens.compactRadius)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: DamsoTokens.compactRadius)
                    .strokeBorder(DamsoTokens.hairline)
            )
    }

    private func correctionSpeakerName(_ speaker: String) -> String {
        guard let record = workspace.selectedRecord else { return speaker }
        let match = record.resolutions.first { $0.speaker == speaker && $0.action != .skip && $0.personName != nil }
        return match?.personName ?? speaker
    }

    private func loadHintsForEditing() {
        let hints = workspace.hints
        participantsText = hints.participants.joined(separator: ", ")
        topicText = hints.topic ?? ""
        domainTermsText = hints.domainTerms.joined(separator: ", ")
        expectedSpeakerCount = hints.numSpeakers ?? 0
    }

    private func saveHints() {
        workspace.updateHints(
            MeetingHints(
                participants: commaSeparated(participantsText),
                topic: topicText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : topicText.trimmingCharacters(in: .whitespacesAndNewlines),
                domainTerms: commaSeparated(domainTermsText),
                numSpeakers: expectedSpeakerCount == 0 ? nil : expectedSpeakerCount
            )
        )
        isHintEditorPresented = false
    }

    private func loadCorrections(for record: MeetingRecord) {
        correctedTitle = record.corrections?.title ?? record.title
        correctedSegments = record.corrections?.transcript ?? record.transcript ?? workspace.processingArtifacts.transcript
        correctedSummaryText = (record.corrections?.summary ?? record.summary)?.oneLine ?? ""
    }

    private func correctedSummary() -> StructuredSummary? {
        let oneLine = correctedSummaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return nil }
        let existing = workspace.selectedRecord?.corrections?.summary ?? workspace.selectedRecord?.summary
        return StructuredSummary(
            oneLine: oneLine,
            keyDiscussion: existing?.keyDiscussion ?? [],
            actionItems: existing?.actionItems ?? [],
            roleHints: existing?.roleHints ?? [:],
            topicSummary: existing?.topicSummary ?? oneLine
        )
    }

    private func commaSeparated(_ value: String) -> [String] {
        value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: Meeting detail

    @ViewBuilder
    private var detail: some View {
        if let record = workspace.selectedRecord {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: DamsoTokens.spacing) {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(sourceEyebrow(record))
                                .font(.damsoEyebrow)
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Text(meetingDisplayTitle(record))
                                .font(.damsoDisplay)
                                .lineLimit(2)
                            detailMetaRow(record)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 6) {
                            StatusPill(title: record.pillTitle, tone: record.pillTone)
                            if workspace.duplicateStems.contains(record.stem) {
                                BlockChip(title: Loc.tr("Possible duplicate"), block: DamsoTokens.blockCream)
                                    .help(Loc.tr("Another recording overlaps this one in time. Nothing is merged or deleted automatically."))
                            }
                        }
                    }

                    HStack(alignment: .center, spacing: 12) {
                        DetailTabBar(selection: $meetingDetailTab)
                            .accessibilityIdentifier("damso.detail-tabs")
                        Spacer(minLength: 8)
                        PipelineStageIndicator(record: record, artifacts: workspace.processingArtifacts)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 18)

                Divider()
                    .overlay(DamsoTokens.hairline)

                ScrollView {
                    detailContent(record)
                        .padding(28)
                }
                .overlay(alignment: .bottomTrailing) {
                    floatingSummaryButton(record)
                }
            }
            .navigationTitle(meetingDetailTab.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button(Loc.tr("Edit meeting"), systemImage: "pencil") {
                        loadCorrections(for: record)
                        isCorrectionPresented = true
                    }
                    Button(Loc.tr("Retry processing"), systemImage: "arrow.clockwise") {
                        Task { await workspace.retrySelectedPhaseOne() }
                    }
                    .disabled(record.originalAudioFile == nil || workspace.isRecording || workspace.state == .processing)
                    Button(Loc.tr("Delete meeting"), systemImage: "trash", role: .destructive) {
                        pendingDelete = record
                    }
                }
            }
            .task(id: record.stem) {
                meetingDetailTab = .overview
                showOriginalTranscript = false
                // Native formats load immediately; ogg/opus first go through
                // the one-time local ffmpeg transcode cache.
                audioPlayer.load(workspace.playbackAudioURL(for: record))
                if workspace.playbackAudioURL(for: record) == nil, workspace.sourceAudioURL(for: record) != nil {
                    let prepared = await workspace.preparePlayableAudio(for: record)
                    if let prepared, workspace.selectedRecord?.stem == record.stem {
                        audioPlayer.load(prepared)
                    }
                }
            }
        } else {
            ContentUnavailableView(Loc.tr("Select a meeting"), systemImage: "rectangle.stack", description: Text(Loc.tr("Choose a meeting from Meeting Log to see its summary, recording, people, and transcript.")))
                .navigationTitle(Loc.tr("Meeting Log"))
        }
    }

    @ViewBuilder
    private func detailContent(_ record: MeetingRecord) -> some View {
        switch meetingDetailTab {
        case .overview:
            overviewView(record)
        case .transcript:
            transcriptView(record)
        case .speakers:
            speakerReview(record)
        }
    }

    private func overviewView(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: DamsoTokens.spacingLG) {
            if workspace.sourceAudioURL(for: record) != nil {
                AudioPlaybackPanel(player: audioPlayer, isPreparing: workspace.isPreparingPlayback)
            }
            meetingStateView(record)
            proposedNotesView(record)
            participantsView(record)
            summaryView(record)
            acceptedNotesView(record)
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func meetingStateView(_ record: MeetingRecord) -> some View {
        if let recoveryAction = workspace.recoveryAction {
            Label(recoveryAction, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(DamsoTokens.warning)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DamsoTokens.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: DamsoTokens.compactRadius))
        }

        switch record.stage {
        case .captured, .queued, .transcribing, .summarizing:
            BlockCard(block: DamsoTokens.blockLime) {
                VStack(alignment: .leading, spacing: 10) {
                    Label(processingTitle(record.stage), systemImage: "waveform.badge.magnifyingglass")
                        .font(.headline)
                    Text(processingDescription(record.stage))
                        .opacity(0.75)
                }
            }
        case .speakerReview:
            // The single call-to-action for speaker confirmation. People and
            // Summary below stay quiet so this prompt never repeats.
            if !allSpeakersResolved(record) {
                BlockCard(block: DamsoTokens.blockLilac) {
                    HStack(alignment: .center, spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                            .font(.title2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(Loc.tr("Confirm the speakers"))
                                .font(.headline)
                            Text(speakerBannerSubtitle())
                                .opacity(0.75)
                        }
                        Spacer()
                        Button(Loc.tr("Review speakers")) { meetingDetailTab = .speakers }
                            .buttonStyle(DamsoPillButtonStyle())
                    }
                }
            }
        case .failed, .quarantined:
            BlockCard(block: DamsoTokens.blockCoral) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Loc.tr("Processing needs attention"))
                            .font(.headline)
                        Text(Loc.tr("Your recording is still stored locally. Retry processing after checking the recovery message above."))
                            .opacity(0.75)
                    }
                    Spacer()
                    Button(Loc.tr("Retry")) { Task { await workspace.retrySelectedPhaseOne() } }
                        .buttonStyle(DamsoPillButtonStyle())
                        .disabled(record.originalAudioFile == nil)
                }
            }
        case .partial:
            BlockCard(block: DamsoTokens.blockCoral) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Loc.tr("Summary stage needs a retry"))
                            .font(.headline)
                        Text(Loc.tr("Speaker confirmations are saved. Only the summary stage runs again."))
                            .opacity(0.75)
                    }
                    Spacer()
                    Button(workspace.isRequestingSummary ? Loc.tr("Retrying...") : Loc.tr("Retry summary")) {
                        Task { await workspace.runSummary() }
                    }
                    .buttonStyle(DamsoPillButtonStyle())
                    .disabled(workspace.isRequestingSummary)
                }
            }
        case .complete:
            EmptyView()
        }
    }

    private func proposedNotesView(_ record: MeetingRecord) -> some View {
        let proposed = (record.personNotes ?? []).filter { $0.status == .proposed }
        return Group {
            if !proposed.isEmpty {
                EditorialSection(title: Loc.tr("Needs your decision")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(Loc.tr("These profile note suggestions came from this meeting. Nothing is saved until you decide."))
                            .font(.damsoMonoCaption)
                            .foregroundStyle(.secondary)
                        ForEach(proposed) { proposal in
                            BlockCard(block: DamsoTokens.blockCream) {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        BlockChip(title: proposal.name, block: DamsoTokens.blockLilac)
                                        Text(Loc.tr("Proposed"))
                                            .font(.damsoMonoCaption)
                                            .opacity(0.6)
                                    }
                                    TextField(Loc.tr("Note"), text: Binding(
                                        get: { editedNotes[proposal.id] ?? proposal.note },
                                        set: { editedNotes[proposal.id] = $0 }
                                    ), axis: .vertical)
                                    .textFieldStyle(.plain)
                                    HStack {
                                        Button(Loc.tr("Add to profile")) {
                                            Task { await workspace.acceptPersonNote(proposal, editedNote: editedNotes[proposal.id]) }
                                        }
                                        .buttonStyle(DamsoPillButtonStyle())
                                        Button(Loc.tr("Decline")) {
                                            workspace.rejectPersonNote(proposal)
                                        }
                                        .buttonStyle(DamsoPillButtonStyle(rank: .secondary))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func acceptedNotesView(_ record: MeetingRecord) -> some View {
        let notes = record.personNotes ?? []
        let accepted = notes.filter { $0.status == .accepted }
        let proposed = notes.filter { $0.status == .proposed }
        return Group {
            if !accepted.isEmpty || (!notes.isEmpty && proposed.isEmpty) {
                EditorialSection(title: Loc.tr("Person notes")) {
                    VStack(alignment: .leading, spacing: 12) {
                        if accepted.isEmpty {
                            Text(Loc.tr("Every proposed note was declined. Profiles stay unchanged."))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(accepted) { note in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(DamsoTokens.success)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.name)
                                        .font(.damsoMonoCaption)
                                        .foregroundStyle(.secondary)
                                    Text(note.note)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func participantsView(_ record: MeetingRecord) -> some View {
        // Route stored names through profile aliases so an absorbed name
        // ("sori") shows as its owning profile, deduplicated.
        let participants: [String] = {
            var seen = Set<String>()
            return participantNames(record).map(displayPersonName).filter { seen.insert($0).inserted }
        }()
        // While voices await confirmation the lilac banner above is the one
        // prompt; an empty People section repeating it stays hidden.
        if participants.isEmpty && !workspace.processingArtifacts.proposals.isEmpty {
            EmptyView()
        } else {
            EditorialSection(title: Loc.tr("People")) {
                VStack(alignment: .leading, spacing: 10) {
                    if participants.isEmpty {
                        Text(Loc.tr("No participants are linked to this meeting yet."))
                            .foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], alignment: .leading, spacing: 8) {
                            ForEach(participants, id: \.self) { participant in
                                participantChip(participant)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func participantChip(_ participant: String) -> some View {
        let profile = personProfile(named: participant)
        Button {
            guard let profile else { return }
            selectedPersonID = profile.id
            libraryDestination = .people
        } label: {
            HStack(spacing: 6) {
                PersonBlockAvatar(name: participant)
                Text(participant)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if profile != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DamsoTokens.compactRadius)
                    .fill(DamsoTokens.blockLilac.fillColor.opacity(profile == nil ? 0.25 : 0.55))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(profile == nil)
        .help(profile == nil ? Loc.tr("No saved profile for this name yet.") : Loc.tr("Open this person's history"))
        .accessibilityLabel(participant)
        .accessibilityHint(profile == nil ? "" : Loc.tr("Open this person's history"))
    }

    private func personProfile(named name: String) -> LocalPersonProfile? {
        let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return workspace.people.first {
            $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == key
        }
    }

    // MARK: Speakers

    private func speakerReview(_ record: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: DamsoTokens.spacing) {
            if workspace.processingArtifacts.proposals.isEmpty {
                Text(record.stage == .transcribing || record.stage == .queued ? Loc.tr("Waiting for local transcription and speaker separation.") : Loc.tr("Speaker cards will appear after local processing completes."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 8) {
                    Text(Loc.tr("Confirm each speaker, then press Generate summary. You can reassign a speaker here at any time."))
                        .font(.damsoMonoCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if workspace.isSuggestingSpeakers {
                        ProgressView()
                            .controlSize(.small)
                        Text(Loc.tr("AI is reading the transcript for suggestions..."))
                            .font(.damsoMonoCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(workspace.processingArtifacts.proposals) { proposal in
                    speakerCard(proposal, record: record)
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Subtitle for the one speaker-confirmation banner, folding in the voice
    /// count so no other section needs to repeat it.
    private func speakerBannerSubtitle() -> String {
        let count = workspace.processingArtifacts.proposals.count
        guard count > 0 else {
            return Loc.tr("Match each detected voice to a person, then generate the summary.")
        }
        return String(format: Loc.tr("%d voices were detected. Match each one to a person, then generate the summary."), count)
    }

    /// Whether every detected speaker has a saved resolution, so the summary
    /// can be generated.
    private func allSpeakersResolved(_ record: MeetingRecord) -> Bool {
        let proposals = workspace.processingArtifacts.proposals
        guard !proposals.isEmpty else { return false }
        return proposals.allSatisfy { proposal in
            record.resolutions.contains { $0.speaker == proposal.speaker }
        }
    }

    /// Explicit summary trigger. The summary no longer starts automatically on
    /// the last confirmation; the user decides when the transcript is sent to
    /// the agent. Floats over the detail pane's bottom-trailing corner so it
    /// stays visible past a long speaker-card list, on every tab.
    @ViewBuilder
    private func floatingSummaryButton(_ record: MeetingRecord) -> some View {
        let hasSummary = record.summary != nil || record.corrections?.summary != nil
        if record.stage == .speakerReview, allSpeakersResolved(record), !hasSummary {
            Button {
                Task { await workspace.runSummary() }
            } label: {
                HStack(spacing: 8) {
                    if workspace.isRequestingSummary {
                        ProgressView()
                            .controlSize(.small)
                            .tint(DamsoTokens.canvas)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(workspace.isRequestingSummary ? Loc.tr("Creating summary...") : Loc.tr("Generate summary"))
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .foregroundStyle(DamsoTokens.canvas)
                .background(DamsoTokens.ink, in: Capsule())
                .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(workspace.isRequestingSummary)
            .padding(20)
            .help(Loc.tr("Sends the transcript to the selected agent to create the summary and title."))
            .accessibilityIdentifier("damso.floating-generate-summary")
        }
    }

    private func speakerCard(_ proposal: SpeakerProposal, record: MeetingRecord) -> some View {
        let resolution = record.resolutions.first(where: { $0.speaker == proposal.speaker })
        let confirmedName = resolution?.action == .skip ? nil : resolution?.personName
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.speaker)
                        .font(.headline)
                    Text("\(durationString(proposal.totalSeconds)) · \(String(format: Loc.tr("%d segments"), proposal.segmentCount))")
                        .font(.damsoMonoCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(title: resolution.map { resolutionTitle($0) } ?? Loc.tr("Needs a person"), tone: resolution == nil ? .pending : .complete)
            }

            if !proposal.excerpts.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Loc.tr("Key remarks"))
                        .font(.damsoEyebrow)
                        .textCase(.uppercase)
                        .foregroundStyle(.secondary)
                    ForEach(proposal.excerpts.prefix(3)) { excerpt in
                        HStack(alignment: .top, spacing: 6) {
                            Text("“")
                                .foregroundStyle(.secondary)
                            Text(excerpt.text)
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }

            if let excerpt = proposal.excerpts.first, let audioURL = workspace.playbackAudioURL(for: record) {
                VStack(alignment: .leading, spacing: 5) {
                    Button(excerptPlayer.isPlaying(excerpt) ? Loc.tr("Stop speaker sample") : Loc.tr("Play speaker sample"), systemImage: excerptPlayer.isPlaying(excerpt) ? "stop.fill" : "play.fill") {
                        excerptPlayer.toggle(audioURL: audioURL, excerpt: excerpt)
                    }
                    .buttonStyle(.bordered)
                    Text(Loc.tr("Plays a short audio section where this speaker was detected. Use it to confirm the person before saving their voice profile."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityHint(Loc.tr("Plays the selected local audio range for this speaker."))
            } else {
                Text(Loc.tr("No playable excerpt is available for this local record."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !proposal.candidates.isEmpty {
                // Stored candidates may carry a name that has since been
                // merged into another profile ("sori"); show the current
                // owner and collapse candidates that now point at the same
                // person, keeping the strongest score.
                let routedCandidates: [(display: String, candidate: SpeakerCandidate)] = {
                    var seen = Set<String>()
                    return proposal.candidates
                        .sorted { $0.voiceScore > $1.voiceScore }
                        .compactMap { candidate in
                            let display = displayPersonName(candidate.name)
                            guard seen.insert(display).inserted else { return nil }
                            return (display, candidate)
                        }
                }()
                VStack(alignment: .leading, spacing: 5) {
                    Text(Loc.tr("Local voice candidates"))
                        .font(.damsoEyebrow)
                        .textCase(.uppercase)
                    ForEach(routedCandidates, id: \.display) { entry in
                        let isChosen = isConfirmedName(entry.display, confirmedName: confirmedName)
                        Button {
                            Task { await workspace.applyResolution(speaker: proposal.speaker, action: .match, personName: entry.display, alias: proposal.suggestedParticipant) }
                        } label: {
                            HStack(spacing: 8) {
                                PersonBlockAvatar(name: entry.display)
                                Text(entry.display)
                                    .fontWeight(isChosen ? .semibold : .regular)
                                Text(scoreString(entry.candidate.voiceScore))
                                    .font(.damsoMonoCaption)
                                    .foregroundStyle(.secondary)
                                if isChosen {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DamsoTokens.success)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(isChosen ? DamsoTokens.success : nil)
                        .disabled(workspace.isApplyingSpeakerResolution)
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                    }
                }
            }

            if !proposal.participantCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Loc.tr("Meeting participants"))
                        .font(.damsoEyebrow)
                        .textCase(.uppercase)
                    ForEach(proposal.participantCandidates, id: \.self) { name in
                        let display = displayPersonName(name)
                        let isSuggested = proposal.suggestedParticipant == name
                        let isChosen = isConfirmedName(name, confirmedName: confirmedName)
                        Button {
                            // A captured name that answers to an existing
                            // profile (by name or alias) confirms that person;
                            // otherwise it creates a new one. Either way the
                            // display name accumulates as an alias.
                            let matched = workspace.people.first { $0.answersTo(name) }
                            Task {
                                await workspace.applyResolution(
                                    speaker: proposal.speaker,
                                    action: matched == nil ? .new : .match,
                                    personName: matched?.name ?? name,
                                    alias: name
                                )
                            }
                        } label: {
                            HStack(spacing: 8) {
                                PersonBlockAvatar(name: display)
                                Text(display)
                                    .fontWeight(isChosen || isSuggested ? .semibold : .regular)
                                if display != name {
                                    Text(name)
                                        .font(.damsoMonoCaption)
                                        .foregroundStyle(.secondary)
                                }
                                if isSuggested {
                                    Label(Loc.tr("Top proposal"), systemImage: "waveform")
                                        .font(.damsoEyebrow)
                                        .foregroundStyle(DamsoTokens.accent)
                                }
                                if isChosen {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(DamsoTokens.success)
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .tint(isChosen ? DamsoTokens.success : (isSuggested ? DamsoTokens.accent : nil))
                        .disabled(workspace.isApplyingSpeakerResolution)
                        .accessibilityAddTraits(isChosen ? .isSelected : [])
                    }
                    Text(Loc.tr("Captured from the live meeting. Confirming saves this display name as a profile alias."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let suggestions = workspace.speakerSuggestions[proposal.speaker], !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Loc.tr("AI suggestions"))
                        .font(.damsoEyebrow)
                        .textCase(.uppercase)
                    ForEach(suggestions) { suggestion in
                        let display = displayPersonName(suggestion.name)
                        let isChosen = isConfirmedName(suggestion.name, confirmedName: confirmedName)
                        VStack(alignment: .leading, spacing: 2) {
                            Button {
                                // Route through aliases so a suggestion naming
                                // an absorbed profile confirms the owner.
                                let matched = workspace.people.first { $0.answersTo(suggestion.name) }
                                Task { await workspace.applyResolution(speaker: proposal.speaker, action: matched == nil ? .new : .match, personName: matched?.name ?? suggestion.name, alias: proposal.suggestedParticipant) }
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(DamsoTokens.accent)
                                    Text(display)
                                        .fontWeight(isChosen ? .semibold : .regular)
                                    Text(scoreString(suggestion.confidence))
                                        .font(.damsoMonoCaption)
                                        .foregroundStyle(.secondary)
                                    if isChosen {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(DamsoTokens.success)
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .tint(isChosen ? DamsoTokens.success : nil)
                            .disabled(workspace.isApplyingSpeakerResolution)
                            .accessibilityAddTraits(isChosen ? .isSelected : [])
                            Text(suggestion.reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Button(Loc.tr("Choose person..."), systemImage: "person.crop.circle.badge.checkmark") {
                    pickerSpeaker = proposal
                }
                Button(Loc.tr("Skip"), systemImage: "arrow.right") {
                    Task { await workspace.applyResolution(speaker: proposal.speaker, action: .skip) }
                }
            }
            .buttonStyle(.bordered)
            .disabled(workspace.isApplyingSpeakerResolution)
        }
        .padding(16)
        .background(DamsoTokens.surfaceSoft, in: RoundedRectangle(cornerRadius: DamsoTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: DamsoTokens.radius).strokeBorder(DamsoTokens.hairline))
        .accessibilityElement(children: .contain)
    }

    // MARK: Transcript and summary

    private func transcriptView(_ record: MeetingRecord) -> some View {
        EditorialSection(title: Loc.tr("Transcript")) {
            let segments = record.corrections?.transcript ?? record.transcript ?? workspace.processingArtifacts.transcript
            // The agent cleanup overlay applies only to unedited transcripts;
            // a user's manual corrections always win over automatic cleanup.
            let cleaned = record.corrections?.transcript == nil ? workspace.processingArtifacts.cleanedTexts : [:]
            if segments.isEmpty {
                Text(Loc.tr("Transcript is available after local processing completes."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    if !cleaned.isEmpty {
                        HStack(spacing: 8) {
                            BlockChip(title: Loc.tr("AI tidied"), block: DamsoTokens.blockLime)
                                .help(Loc.tr("Leftover transcription artifacts were removed by the agent. The original recording text is kept unchanged."))
                            Text(String(format: Loc.tr("%d segments tidied"), cleaned.count))
                                .font(.damsoMonoCaption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Toggle(Loc.tr("Show original"), isOn: $showOriginalTranscript)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                    }
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                        let display = (!showOriginalTranscript ? cleaned[index] : nil) ?? segment.text
                        if !display.isEmpty {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(segment.speaker) · \(timestamp(segment.startSeconds))")
                                    .font(.damsoMonoCaption)
                                    .foregroundStyle(.secondary)
                                Text(display)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func summaryView(_ record: MeetingRecord) -> some View {
        EditorialSection(title: Loc.tr("Summary")) {
            if let summary = record.corrections?.summary ?? record.summary {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary.oneLine)
                        .font(.title3.weight(.semibold))
                    if !summary.keyDiscussion.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Loc.tr("Key points"))
                                .font(.damsoEyebrow)
                                .textCase(.uppercase)
                            ForEach(summary.keyDiscussion, id: \.self) { point in
                                Label(point, systemImage: "text.bullet")
                            }
                        }
                    }
                    if !summary.actionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Loc.tr("Action items"))
                                .font(.damsoEyebrow)
                                .textCase(.uppercase)
                            ForEach(summary.actionItems, id: \.self) { item in
                                Label(item, systemImage: "checkmark.circle")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if [.captured, .queued, .transcribing].contains(record.stage) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Loc.tr("Summary will appear here"))
                        .font(.headline)
                    Text(Loc.tr("Local transcription and speaker separation are still running."))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if record.stage == .speakerReview {
                if allSpeakersResolved(record) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(Loc.tr("Ready to summarize"))
                            .font(.headline)
                        Text(Loc.tr("Every speaker is confirmed. Press Generate summary at the bottom right to create the summary and title."))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(Loc.tr("The summary and title are created after the speakers are confirmed."))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if record.stage == .summarizing {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Loc.tr("Creating the summary"))
                        .font(.headline)
                    Text(Loc.tr("The reviewed transcript is being summarized by your selected agent."))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(Loc.tr("No summary was saved for this meeting yet."))
                        .foregroundStyle(.secondary)
                    Button(workspace.isRequestingSummary ? Loc.tr("Creating summary...") : Loc.tr("Retry summary"), systemImage: "sparkles") {
                        Task { await workspace.runSummary() }
                    }
                    .buttonStyle(DamsoPillButtonStyle())
                    .disabled(workspace.isRequestingSummary || workspace.isApplyingSpeakerResolution || workspace.isRecording || workspace.processingArtifacts.transcript.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Helpers

    private func sourceEyebrow(_ record: MeetingRecord) -> String {
        externalProviderName(record.source).map { String(format: Loc.tr("Imported via External Sync (%@)"), $0) } ?? Loc.tr("Recorded on this Mac")
    }

    /// Date, time, duration, and people at a glance under the title.
    private func detailMetaRow(_ record: MeetingRecord) -> some View {
        HStack(spacing: 14) {
            Label(record.createdAt.formatted(date: .complete, time: .omitted), systemImage: "calendar")
            Label(timeAndDuration(record), systemImage: "clock")
            let speakerCount = participantNames(record).count
            if speakerCount > 0 {
                Label(String(format: Loc.tr("%d people"), speakerCount), systemImage: "person.2")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func timeAndDuration(_ record: MeetingRecord) -> String {
        let time = record.createdAt.formatted(date: .omitted, time: .shortened)
        guard let seconds = record.durationSeconds, seconds > 0 else { return time }
        let minutes = max(1, Int((seconds / 60).rounded()))
        return "\(time) · \(String(format: Loc.tr("%d min"), minutes))"
    }

    /// Routes a stored person name (possibly an absorbed alias like "sori")
    /// to the profile that owns it now, so every surface shows one identity.
    private func displayPersonName(_ name: String) -> String {
        workspace.people.first { $0.answersTo(name) }?.name ?? name
    }

    private func participantNames(_ record: MeetingRecord) -> [String] {
        var seen = Set<String>()
        let resolved = record.resolutions.compactMap { resolution -> String? in
            guard resolution.action != .skip else { return nil }
            return resolution.personName?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (resolved + record.hints.participants).compactMap { name in
            guard !name.isEmpty else { return nil }
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return name
        }
    }

    private func processingTitle(_ stage: ProcessingStage) -> String {
        switch stage {
        case .captured, .queued: Loc.tr("Waiting to process")
        case .transcribing: Loc.tr("Transcribing on this Mac")
        case .summarizing: Loc.tr("Creating the summary")
        default: Loc.tr("Processing")
        }
    }

    private func processingDescription(_ stage: ProcessingStage) -> String {
        switch stage {
        case .captured, .queued: Loc.tr("The recording is safe. Local processing will start when the queue is ready.")
        case .transcribing: Loc.tr("Whisper is creating the transcript and Sherpa is separating speakers locally.")
        case .summarizing: Loc.tr("The reviewed transcript is being summarized. The title updates automatically when it finishes.")
        default: Loc.tr("Meeting results will update here as each local step finishes.")
        }
    }

    private var selectedPerson: LocalPersonProfile? {
        guard let selectedPersonID else { return workspace.people.first }
        return workspace.people.first { $0.id == selectedPersonID }
    }

    private func meetings(for person: LocalPersonProfile) -> [MeetingRecord] {
        let key = person.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return workspace.records.filter { record in
            record.resolutions.contains { resolution in
                guard resolution.action != .skip, let name = resolution.personName else { return false }
                return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == key
            }
        }
    }

    private func speakingSummary(for person: LocalPersonProfile, in record: MeetingRecord) -> String {
        let key = person.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let speakerLabels = record.resolutions.filter { resolution in
            guard resolution.action != .skip, let name = resolution.personName else { return false }
            return name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) == key
        }.map(\.speaker)
        let artifacts = (try? workspace.processingArtifactsSnapshot(stem: record.stem)) ?? .empty
        let seconds = artifacts.proposals.filter { speakerLabels.contains($0.speaker) }.reduce(0.0) { $0 + $1.totalSeconds }
        guard seconds > 0 else { return Loc.tr("confirmed") }
        return String(format: Loc.tr("%@ of speech"), durationString(seconds))
    }

    private func personSubtitle(_ person: LocalPersonProfile) -> String {
        var values = [String(format: Loc.tr("%d confirmed meetings"), person.meetingCount)]
        if person.hasVoiceProfile { values.append(Loc.tr("voice profile ready")) }
        return values.joined(separator: " · ")
    }

    private func durationString(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return "\(whole / 60)m \(whole % 60)s"
    }

    private func timestamp(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    private func scoreString(_ score: Double) -> String {
        String(format: "%.0f%%", score * 100)
    }

    private func isConfirmedName(_ name: String, confirmedName: String?) -> Bool {
        guard let confirmedName else { return false }
        // Compare through profile aliases so a resolution saved under an old
        // name ("sori") still marks the merged owner as chosen.
        return displayPersonName(confirmedName).localizedCaseInsensitiveCompare(displayPersonName(name)) == .orderedSame
    }

    private func resolutionTitle(_ resolution: SpeakerResolution) -> String {
        switch resolution.action {
        case .skip: Loc.tr("Skipped")
        case .match, .new, .me: resolution.personName.map { displayPersonName($0) } ?? Loc.tr("Confirmed")
        }
    }

}

// MARK: Pipeline stage indicator

/// The four-stage journey of one meeting. Each stage is a pastel block that
/// reads identically in light and dark; the current stage carries a stronger
/// fill and failed stages switch to the coral block with a retry-oriented
/// label. States derive from the record's stage journal and artifacts.
struct PipelineStageIndicator: View {
    enum StepState {
        case complete
        case current
        case failed
        case pending
    }

    let record: MeetingRecord
    let artifacts: MeetingProcessingArtifacts

    private var steps: [(title: String, block: DamsoBlockColor, state: StepState)] {
        let hasTranscript = !artifacts.transcript.isEmpty
        let allResolved = !artifacts.proposals.isEmpty && artifacts.proposals.allSatisfy { proposal in
            record.resolutions.contains { $0.speaker == proposal.speaker }
        }
        let hasSummary = record.summary != nil || record.corrections?.summary != nil

        let capture: StepState = record.stage == .failed && !hasTranscript ? .failed : .complete
        let transcribe: StepState
        switch record.stage {
        case .captured, .queued, .transcribing:
            transcribe = record.stage == .failed ? .failed : .current
        case .failed, .quarantined:
            transcribe = hasTranscript ? .complete : .failed
        default:
            transcribe = hasTranscript ? .complete : .pending
        }
        let speakers: StepState
        if allResolved {
            speakers = .complete
        } else if record.stage == .speakerReview {
            speakers = .current
        } else {
            speakers = .pending
        }
        let summary: StepState
        switch record.stage {
        case .summarizing: summary = .current
        case .partial: summary = .failed
        case .complete: summary = hasSummary ? .complete : .pending
        default: summary = hasSummary ? .complete : .pending
        }
        return [
            (Loc.tr("Captured"), DamsoTokens.blockCream, capture),
            (Loc.tr("Transcribed"), DamsoTokens.blockLime, transcribe),
            (Loc.tr("Speakers"), DamsoTokens.blockLilac, speakers),
            (Loc.tr("Summary"), DamsoTokens.blockMint, summary),
        ]
    }

    var body: some View {
        HStack(spacing: DamsoTokens.spacingXS) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                StageSegment(title: step.title, block: step.block, state: step.state)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Loc.tr("Pipeline progress"))
    }
}

private struct StageSegment: View {
    let title: String
    let block: DamsoBlockColor
    let state: PipelineStageIndicator.StepState

    private var effectiveBlock: DamsoBlockColor {
        state == .failed ? DamsoTokens.blockCoral : block
    }

    private var icon: String {
        switch state {
        case .complete: "checkmark"
        case .current: "arrow.right"
        case .failed: "exclamationmark.triangle.fill"
        case .pending: "circle"
        }
    }

    private var stateName: String {
        switch state {
        case .complete: Loc.tr("complete")
        case .current: Loc.tr("in progress")
        case .failed: Loc.tr("failed")
        case .pending: Loc.tr("pending")
        }
    }

    var body: some View {
        // Compact intrinsic-width chip: the four stages read as a small strip
        // beside the tab bar instead of a full-width row.
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2.weight(.bold))
                .symbolEffect(.pulse, options: .repeating, isActive: state == .current)
            Text(title)
                .font(.damsoEyebrow)
                .textCase(.uppercase)
                .lineLimit(1)
        }
        .foregroundStyle(state == .pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(effectiveBlock.inkColor))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DamsoTokens.radiusSM)
                .fill(state == .pending ? AnyShapeStyle(DamsoTokens.surfaceSoft) : AnyShapeStyle(effectiveBlock.fillColor.opacity(state == .current ? 1 : 0.55)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DamsoTokens.radiusSM)
                .strokeBorder(state == .current ? effectiveBlock.inkColor.opacity(0.7) : DamsoTokens.hairline, lineWidth: state == .current ? 1.5 : 1)
        )
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(stateName)")
    }
}

// MARK: Person picker

/// Searchable person picker: choose an existing profile, mark the speaker as
/// yourself, or create a new person right here — one modal for the whole
/// decision, as every profile action stays an explicit user choice.
/// The full profile-merge flow (R7): pick the duplicate, choose which name
/// stays (primary), preview exactly what transfers, then execute. Self-merge
/// is impossible by construction: the current profile is excluded from the
/// duplicate list.
private struct ProfileMergeSheet: View {
    let current: LocalPersonProfile
    let others: [LocalPersonProfile]
    let onMerge: (_ primary: LocalPersonProfile, _ absorbed: LocalPersonProfile) -> Void
    let onCancel: () -> Void

    @State private var search = ""
    @State private var selectedOtherID: String?
    @State private var keepCurrentName = true

    private var filtered: [LocalPersonProfile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return others }
        return others.filter { $0.matches(query: query) }
    }

    private var selectedOther: LocalPersonProfile? {
        others.first { $0.id == selectedOtherID }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if let other = selectedOther {
                    confirmation(other: other)
                } else {
                    picker
                }
            }
            .navigationTitle(String(format: Loc.tr("Merge %@ with..."), current.name))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("Cancel")) { onCancel() }
                }
            }
        }
        .frame(width: 480, height: 560)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField(Loc.tr("Search people"), text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            List {
                if filtered.isEmpty {
                    Text(Loc.tr("No matching people"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered) { person in
                        Button {
                            selectedOtherID = person.id
                        } label: {
                            HStack(spacing: 10) {
                                PersonBlockAvatar(name: person.name)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(person.name)
                                    Text(String(format: Loc.tr("%d confirmed meetings"), person.meetingCount) + (person.hasVoiceProfile ? " · " + Loc.tr("voice profile ready") : ""))
                                        .font(.damsoMonoCaption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func confirmation(other: LocalPersonProfile) -> some View {
        let primary = keepCurrentName ? current : other
        let absorbed = keepCurrentName ? other : current
        return ScrollView {
            VStack(alignment: .leading, spacing: DamsoTokens.spacing) {
                Picker(Loc.tr("Name to keep"), selection: $keepCurrentName) {
                    Text(current.name).tag(true)
                    Text(other.name).tag(false)
                }
                .pickerStyle(.segmented)

                EditorialSection(title: Loc.tr("What transfers")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(String(format: Loc.tr("%d confirmed meetings"), absorbed.meetingCount), systemImage: "rectangle.stack")
                        Label(
                            absorbed.hasVoiceProfile
                                ? (primary.hasVoiceProfile
                                    ? Loc.tr("Voice profile: the kept name's voice profile stays; the absorbed one remains in the archive")
                                    : Loc.tr("Voice profile moves to the kept name"))
                                : Loc.tr("No voice profile to transfer"),
                            systemImage: "waveform"
                        )
                        Label(
                            absorbed.aliases.isEmpty
                                ? String(format: Loc.tr("Alias added: %@"), absorbed.name)
                                : String(format: Loc.tr("Aliases added: %@"), ([absorbed.name] + absorbed.aliases).joined(separator: ", ")),
                            systemImage: "person.text.rectangle"
                        )
                        Label(Loc.tr("Profile notes are appended to the kept profile"), systemImage: "note.text")
                    }
                    .font(.callout)
                }

                Text(String(format: Loc.tr("“%@” is archived under peoples/archive before anything moves. Restore = move the folder back and rebuild the index."), absorbed.name))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button(Loc.tr("Back")) { selectedOtherID = nil }
                        .buttonStyle(DamsoPillButtonStyle(rank: .secondary))
                    Spacer()
                    Button(String(format: Loc.tr("Merge into “%@”"), primary.name)) {
                        onMerge(primary, absorbed)
                    }
                    .buttonStyle(DamsoPillButtonStyle())
                }
            }
            .padding(20)
        }
    }
}

private struct PersonPickerSheet: View {
    let speaker: String
    let people: [LocalPersonProfile]
    let onSelect: (String, SpeakerResolutionAction) -> Void
    let onCancel: () -> Void

    @State private var search = ""

    private var filtered: [LocalPersonProfile] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return people }
        // Aliases participate in search so a captured display name finds the
        // profile it was confirmed into (R9).
        return people.filter { $0.matches(query: query) }
    }

    private var trimmedSearch: String {
        search.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasExactMatch: Bool {
        people.contains { $0.name.localizedCaseInsensitiveCompare(trimmedSearch) == .orderedSame }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                TextField(Loc.tr("Search people"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                List {
                    Button {
                        onSelect(MyProfilePreferences.displayName(), .me)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(DamsoTokens.accent)
                            Text(Loc.tr("This is me"))
                                .font(.body.weight(.medium))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if !trimmedSearch.isEmpty && !hasExactMatch {
                        Button {
                            onSelect(trimmedSearch, .new)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "person.badge.plus")
                                    .foregroundStyle(DamsoTokens.success)
                                Text(String(format: Loc.tr("Create “%@” as a new person"), trimmedSearch))
                                    .font(.body.weight(.medium))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    Section(Loc.tr("People")) {
                        if filtered.isEmpty {
                            Text(Loc.tr("No matching people"))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(filtered) { person in
                                Button {
                                    onSelect(person.name, .match)
                                } label: {
                                    HStack(spacing: 10) {
                                        PersonBlockAvatar(name: person.name)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(person.name)
                                            Text(String(format: Loc.tr("%d confirmed meetings"), person.meetingCount) + (person.hasVoiceProfile ? " · " + Loc.tr("voice profile ready") : ""))
                                                .font(.damsoMonoCaption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
            .navigationTitle(String(format: Loc.tr("Choose a person for %@"), speaker))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Loc.tr("Cancel")) { onCancel() }
                }
            }
        }
        .frame(width: 460, height: 520)
    }
}

// MARK: Shared editorial components

/// A titled content section: mono uppercase eyebrow over a hairline-ruled
/// content block, replacing the stock GroupBox look.
struct EditorialSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.damsoEyebrow)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Divider()
                .overlay(DamsoTokens.hairline)
            content
        }
    }
}

/// A pastel sticky-note card. Ink text on the block fill in both appearances.
struct BlockCard<Content: View>: View {
    let block: DamsoBlockColor
    @ViewBuilder var content: Content

    var body: some View {
        content
            .foregroundStyle(block.inkColor)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(block.fillColor, in: RoundedRectangle(cornerRadius: DamsoTokens.radius))
    }
}

/// A square pastel avatar with the person's leading character, deterministic
/// per name so a person keeps their block color everywhere.
struct PersonBlockAvatar: View {
    let name: String
    var large = false

    private var block: DamsoBlockColor {
        let palette = [DamsoTokens.blockLime, DamsoTokens.blockLilac, DamsoTokens.blockMint, DamsoTokens.blockPink, DamsoTokens.blockCoral, DamsoTokens.blockCream]
        var hash = 0
        for scalar in name.unicodeScalars { hash = (hash &* 31 &+ Int(scalar.value)) & 0xFFFF }
        return palette[hash % palette.count]
    }

    var body: some View {
        Text(String(name.prefix(1)))
            .font(large ? .title.weight(.semibold) : .caption.weight(.semibold))
            .foregroundStyle(block.inkColor)
            .frame(width: large ? 52 : 24, height: large ? 52 : 24)
            .background(block.fillColor, in: RoundedRectangle(cornerRadius: large ? DamsoTokens.compactRadius : DamsoTokens.radiusXS))
            .accessibilityHidden(true)
    }
}

private enum LibraryDestination: String, Hashable {
    case people
    case meetingLog
}

/// Meeting list filter over the pipeline stage journal, grouped into the four
/// states a user acts on rather than the raw nine-stage enum.
private enum MeetingStageFilter: String, CaseIterable, Hashable {
    case all
    case inProgress
    case speakerReview
    case needsAttention
    case complete

    var title: String {
        switch self {
        case .all: Loc.tr("All stages")
        case .inProgress: Loc.tr("In progress")
        case .speakerReview: Loc.tr("Speakers need confirmation")
        case .needsAttention: Loc.tr("Needs attention")
        case .complete: Loc.tr("Complete")
        }
    }

    func matches(_ stage: ProcessingStage) -> Bool {
        switch self {
        case .all: true
        case .inProgress: [.captured, .queued, .transcribing, .summarizing].contains(stage)
        case .speakerReview: stage == .speakerReview
        case .needsAttention: [.partial, .failed, .quarantined].contains(stage)
        case .complete: stage == .complete
        }
    }
}

private enum MeetingSourceFilter: String, CaseIterable, Hashable {
    case all
    case local
    case imported

    var title: String {
        switch self {
        case .all: Loc.tr("All sources")
        case .local: Loc.tr("Recorded on this Mac")
        case .imported: Loc.tr("External Sync")
        }
    }

    func matches(_ source: MeetingSource) -> Bool {
        switch self {
        case .all: true
        case .local: source == .local
        case .imported: source == .plaud
        }
    }
}

private enum MeetingDetailTab: String, CaseIterable, Hashable {
    case overview
    case transcript
    case speakers

    var title: String {
        switch self {
        case .overview: Loc.tr("Overview")
        case .transcript: Loc.tr("Transcript")
        case .speakers: Loc.tr("Speakers")
        }
    }
}

/// The hero capture control: one confident ink block when idle, flipping to
/// the live magenta block with a running timer while recording. The visual
/// language mirrors the pill button (ink fill, canvas ink) scaled up to the
/// sidebar's primary action.
private struct RecordHeroButton: View {
    let isRecording: Bool
    let isPending: Bool
    let action: () -> Void

    @State private var startedAt: Date?
    @State private var isHovering = false
    @State private var livePulse = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(DamsoTokens.canvas)
                        .frame(width: 40, height: 40)
                    if isPending {
                        ProgressView()
                            .controlSize(.small)
                    } else if isRecording {
                        RoundedRectangle(cornerRadius: 3.5)
                            .fill(DamsoTokens.critical)
                            .frame(width: 15, height: 15)
                    } else {
                        Circle()
                            .fill(DamsoTokens.critical)
                            .frame(width: 17, height: 17)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(isRecording ? Loc.tr("Stop recording") : Loc.tr("Record now"))
                        .font(.title3.weight(.semibold))
                    if isRecording {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(elapsedString(now: context.date))
                                .font(.damsoEyebrow)
                                .monospacedDigit()
                                .opacity(0.8)
                        }
                    } else {
                        Text(Loc.tr("Mic + system audio"))
                            .font(.damsoEyebrow)
                            .opacity(0.65)
                    }
                }
                Spacer(minLength: 0)
                if isRecording {
                    Circle()
                        .fill(DamsoTokens.canvas)
                        .frame(width: 8, height: 8)
                        .opacity(livePulse ? 1 : 0.2)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: livePulse)
                }
            }
            .foregroundStyle(DamsoTokens.canvas)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DamsoTokens.radius)
                    .fill(isRecording ? DamsoTokens.critical : DamsoTokens.ink)
            )
            .shadow(color: .black.opacity(isHovering ? 0.28 : 0.16), radius: isHovering ? 12 : 7, y: 3)
            .scaleEffect(isHovering && !isPending ? 1.015 : 1)
            .contentShape(RoundedRectangle(cornerRadius: DamsoTokens.radius))
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .animation(.spring(duration: 0.25), value: isHovering)
        .animation(.spring(duration: 0.3), value: isRecording)
        .onHover { isHovering = $0 }
        .onAppear {
            if isRecording {
                startedAt = startedAt ?? .now
                livePulse = true
            }
        }
        .onChange(of: isRecording) { _, recording in
            startedAt = recording ? .now : nil
            livePulse = recording
        }
    }

    private func elapsedString(now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(startedAt ?? now)))
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// One provider row in the sidebar's External Sync section, rendering the
/// four account states (not connected / syncing / connected / needs
/// attention) with the manual "Sync now" trigger and inline result (R7).
private struct ExternalSyncProviderRow: View {
    let provider: ExternalSyncController.ProviderViewState
    let onSyncNow: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Label(provider.displayName, systemImage: "arrow.triangle.2.circlepath")
                    .lineLimit(1)
                Spacer(minLength: 4)
                trailingControl
            }
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleIsWarning ? DamsoTokens.warning : .secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !provider.isConnected || provider.needsRelogin { onOpenSettings() }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if provider.isSyncing {
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel(Loc.tr("Sync in progress"))
        } else if provider.needsRelogin || isErrorState {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DamsoTokens.warning)
                .accessibilityLabel(Loc.tr("Needs attention"))
        } else if provider.isConnected {
            Button(Loc.tr("Sync now"), systemImage: "arrow.clockwise") {
                onSyncNow()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(DamsoTokens.accent)
            .accessibilityLabel(String(format: Loc.tr("Sync %@ now"), provider.displayName))
        }
    }

    private var isErrorState: Bool {
        if case .error = provider.accountState { return true }
        return false
    }

    private var subtitleIsWarning: Bool {
        provider.needsRelogin || isErrorState || provider.lastFailureCode != nil
    }

    private var subtitle: String? {
        if provider.isSyncing { return Loc.tr("Syncing...") }
        if provider.needsRelogin { return Loc.tr("Re-login needed · open Settings") }
        switch provider.accountState {
        case .notInstalled: return Loc.tr("Not connected · open Settings")
        case .needsLogin: return Loc.tr("Not connected · open Settings")
        case .error: return Loc.tr("Service unavailable · will retry")
        case .connected:
            if let inline = provider.inlineResult { return inline }
            if let lastSyncAt = provider.lastSyncAt {
                return String(format: Loc.tr("Last synced %@"), lastSyncAt.formatted(date: .omitted, time: .shortened))
            }
            return provider.hasCheckedAccount ? Loc.tr("Waiting for the first sync") : nil
        }
    }
}

private struct SidebarDestinationRow: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.vertical, 6)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
        .foregroundStyle(selected ? DamsoTokens.accent : Color.primary)
        .fontWeight(selected ? .semibold : .regular)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Pill-style detail section switcher replacing the stock segmented picker:
/// the selected tab is a solid ink capsule inside a soft track.
private struct DetailTabBar: View {
    @Binding var selection: MeetingDetailTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MeetingDetailTab.allCases, id: \.self) { tab in
                let isSelected = selection == tab
                Button {
                    withAnimation(.snappy(duration: 0.18)) { selection = tab }
                } label: {
                    Text(tab.title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .foregroundStyle(isSelected ? DamsoTokens.canvas : DamsoTokens.inkSecondary)
                        .background(Capsule().fill(isSelected ? DamsoTokens.ink : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(DamsoTokens.surfaceSoft))
        .overlay(Capsule().strokeBorder(DamsoTokens.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Loc.tr("Meeting section"))
    }
}

private struct AudioPlaybackPanel: View {
    @ObservedObject var player: LocalAudioPlayer
    var isPreparing = false

    private var progress: Double {
        guard player.duration > 0 else { return 0 }
        return min(max(0, player.currentTime / player.duration), 1)
    }

    var body: some View {
        Group {
            if isPreparing {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(Loc.tr("Preparing audio for playback..."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DamsoTokens.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 14) {
                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(DamsoTokens.canvas)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(DamsoTokens.ink))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(player.isPlaying ? Loc.tr("Pause recording") : Loc.tr("Play recording"))

                    VStack(alignment: .leading, spacing: 6) {
                        WaveformView(samples: player.samples, progress: progress) { fraction in
                            player.seek(to: fraction)
                        }
                        .frame(height: 40)

                        HStack(spacing: 10) {
                            Text(playbackTimestamp(player.currentTime))
                                .font(.damsoMonoCaption)
                                .foregroundStyle(DamsoTokens.ink)
                                .monospacedDigit()
                            Button(Loc.tr("Back 15 seconds"), systemImage: "gobackward.15") { player.skip(seconds: -15) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(DamsoTokens.inkSecondary)
                            Button(Loc.tr("Forward 15 seconds"), systemImage: "goforward.15") { player.skip(seconds: 15) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(DamsoTokens.inkSecondary)
                            Spacer()
                            Text(playbackTimestamp(player.duration))
                                .font(.damsoMonoCaption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: DamsoTokens.radius)
                .fill(DamsoTokens.surfaceSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DamsoTokens.radius)
                .strokeBorder(DamsoTokens.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func playbackTimestamp(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        if whole >= 3600 {
            return String(format: "%d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
        }
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

private struct WaveformView: View {
    let samples: [Float]
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let values = samples.isEmpty ? Array(repeating: Float(0.12), count: 96) : samples
                let gap: CGFloat = 1.5
                let width = max(1, (size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count))
                for (index, value) in values.enumerated() {
                    let height = max(4, CGFloat(value) * size.height)
                    let x = CGFloat(index) * (width + gap)
                    let rect = CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
                    let fraction = Double(index + 1) / Double(values.count)
                    context.fill(Path(roundedRect: rect, cornerRadius: width / 2), with: .color(fraction <= progress ? DamsoTokens.accent : Color.secondary.opacity(0.28)))
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                onSeek(min(max(0, value.location.x / max(1, proxy.size.width)), 1))
            })
        }
        .accessibilityElement()
        .accessibilityLabel(Loc.tr("Recording waveform"))
        .accessibilityValue(String(format: Loc.tr("%d percent played"), Int(progress * 100)))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(1, progress + 0.05))
            case .decrement: onSeek(max(0, progress - 0.05))
            @unknown default: break
            }
        }
    }
}

/// Display name of the External Sync provider a meeting came from, nil for
/// local recordings. Presentation-only mapping; the storage schema stays
/// provider-neutral.
private func externalProviderName(_ source: MeetingSource) -> String? {
    switch source {
    case .local: nil
    case .plaud: "Plaud"
    }
}

private func meetingDisplayTitle(_ record: MeetingRecord) -> String {
    let title = (record.corrections?.title ?? record.title).trimmingCharacters(in: .whitespacesAndNewlines)
    let audioExtensions = Set(["mp3", "m4a", "wav", "aiff", "aif", "caf", "ogg", "opus", "webm"])
    let looksLikeAudioFilename = audioExtensions.contains((title as NSString).pathExtension.lowercased())
    let basename = (title as NSString).deletingPathExtension
    let looksLikeOpaqueIdentifier = basename.count >= 24 && basename.allSatisfy { $0.isHexDigit }
    guard title.isEmpty || looksLikeAudioFilename || looksLikeOpaqueIdentifier else { return title }
    return String(format: Loc.tr("Meeting on %@"), record.createdAt.formatted(date: .abbreviated, time: .omitted))
}

private struct MeetingRow: View {
    let record: MeetingRecord
    let selected: Bool
    let duplicateSuspect: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.source == .local ? "laptopcomputer" : "arrow.triangle.2.circlepath")
                .foregroundStyle(DamsoTokens.inkSecondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(meetingDisplayTitle(record))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.damsoMonoCaption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    StatusPill(title: record.pillTitle, tone: record.pillTone)
                    if let provider = externalProviderName(record.source) {
                        BlockChip(title: provider, block: DamsoTokens.blockLilac)
                    }
                    if duplicateSuspect {
                        BlockChip(title: Loc.tr("Duplicate?"), block: DamsoTokens.blockCream)
                    }
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(DamsoTokens.accent)
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

}

@MainActor
private final class LocalExcerptPlayer: ObservableObject {
    @Published private var activeExcerptID: String?
    private var player: AVAudioPlayer?
    private var stopTask: Task<Void, Never>?

    func isPlaying(_ excerpt: SpeakerExcerpt) -> Bool {
        activeExcerptID == excerpt.id
    }

    func toggle(audioURL: URL, excerpt: SpeakerExcerpt) {
        if isPlaying(excerpt) {
            stop()
            return
        }
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.prepareToPlay()
            player.currentTime = min(max(0, excerpt.startSeconds), player.duration)
            guard player.play() else { return }
            self.player = player
            activeExcerptID = excerpt.id
            let duration = max(0.25, min(excerpt.endSeconds - excerpt.startSeconds, player.duration - player.currentTime))
            stopTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stop()
            }
        } catch {
            stop()
        }
    }

    private func stop() {
        stopTask?.cancel()
        stopTask = nil
        player?.stop()
        player = nil
        activeExcerptID = nil
    }
}
