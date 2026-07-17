import SwiftUI

/// Pane for the automatic summary agent. Selecting an unavailable agent is
/// allowed but surfaces a dependency state instead of silently falling back.
struct AgentSettingsView: View {
    @AppStorage(AgentPreferences.agentKey) private var agentSetting = SummaryAgent.claude.rawValue
    @State private var availability: [SummaryAgent: Bool] = [:]

    var body: some View {
        SettingsGroup(title: Loc.tr("Summary agent")) {
            SettingsRow(title: Loc.tr("Default agent")) {
                Picker("", selection: $agentSetting) {
                    ForEach(SummaryAgent.allCases, id: \.rawValue) { agent in
                        Text(agent.displayName).tag(agent.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            ForEach(SummaryAgent.allCases, id: \.rawValue) { agent in
                SettingsRow(title: agent.displayName) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor(for: agent))
                            .frame(width: 8, height: 8)
                        Text(statusText(for: agent))
                            .font(.damsoMonoCaption)
                            .foregroundStyle(DamsoTokens.inkSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            SettingsFootnote(text: Loc.tr("After the speakers of a meeting are confirmed, the transcript text is sent to the selected agent CLI to create the summary and title automatically. There is no automatic fallback to the other agent."))
        }
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
}
