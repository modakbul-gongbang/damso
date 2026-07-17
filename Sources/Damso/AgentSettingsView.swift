import SwiftUI

/// Settings for the automatic summary agent, the app/output language, and
/// the derived search index. Selecting an unavailable agent is allowed but
/// surfaces a dependency state instead of silently falling back.
struct AgentSettingsView: View {
    @AppStorage(AgentPreferences.agentKey) private var agentSetting = SummaryAgent.claude.rawValue
    @AppStorage(AgentPreferences.languageKey) private var languageSetting = SummaryLanguage.korean.rawValue
    @State private var availability: [SummaryAgent: Bool] = [:]
    @State private var isRebuildingIndex = false
    @State private var indexMessage: String?

    var body: some View {
        Form {
            Section(Loc.tr("Summary agent")) {
                Picker(Loc.tr("Default agent"), selection: $agentSetting) {
                    ForEach(SummaryAgent.allCases, id: \.rawValue) { agent in
                        Text(agent.displayName).tag(agent.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                ForEach(SummaryAgent.allCases, id: \.rawValue) { agent in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor(for: agent))
                            .frame(width: 8, height: 8)
                        Text(agent.displayName)
                        Spacer()
                        Text(statusText(for: agent))
                            .font(.damsoMonoCaption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(Loc.tr("After the speakers of a meeting are confirmed, the transcript text is sent to the selected agent CLI to create the summary and title automatically. There is no automatic fallback to the other agent."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(Loc.tr("Language")) {
                Picker(Loc.tr("App and output language"), selection: $languageSetting) {
                    Text("한국어").tag(SummaryLanguage.korean.rawValue)
                    Text("English").tag(SummaryLanguage.english.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text(Loc.tr("Applies to the interface and to generated summaries, titles, and person notes."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section(Loc.tr("Search index")) {
                HStack {
                    Button(isRebuildingIndex ? Loc.tr("Rebuilding...") : Loc.tr("Rebuild search index")) {
                        rebuildIndex()
                    }
                    .disabled(isRebuildingIndex)
                    if let indexMessage {
                        Text(indexMessage)
                            .font(.damsoMonoCaption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(Loc.tr("The SQLite index is derived from your local meeting files and can always be rebuilt from them. Rebuilding never changes a meeting file."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .task { refreshAvailability() }
    }

    private func statusColor(for agent: SummaryAgent) -> Color {
        switch availability[agent] {
        case .some(true): DamsoTokens.success
        case .some(false): DamsoTokens.warning
        case .none: DamsoTokens.inkSecondary
        }
    }

    private func statusText(for agent: SummaryAgent) -> String {
        switch availability[agent] {
        case .some(true): Loc.tr("CLI found")
        case .some(false): Loc.tr("CLI not found on PATH")
        case .none: Loc.tr("checking...")
        }
    }

    private func refreshAvailability() {
        Task.detached(priority: .utility) {
            var result: [SummaryAgent: Bool] = [:]
            for agent in SummaryAgent.allCases {
                result[agent] = AgentPreferences.isAgentAvailable(agent)
            }
            let snapshot = result
            await MainActor.run { availability = snapshot }
        }
    }

    private func rebuildIndex() {
        isRebuildingIndex = true
        indexMessage = nil
        let root = StorageRootConfiguration().makeStore().rootURL.path
        Task.detached(priority: .utility) {
            let result = Result { try LocalIndexProcessRunner.rebuild(storeRoot: root) }
            await MainActor.run {
                isRebuildingIndex = false
                switch result {
                case .success(let report):
                    indexMessage = String(format: Loc.tr("Indexed %d meetings."), report.meetings ?? 0)
                case .failure:
                    indexMessage = Loc.tr("Rebuild failed. Check that Python and the store root are available.")
                }
            }
        }
    }
}
