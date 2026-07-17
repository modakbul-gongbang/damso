import SwiftUI

/// Preferences for the owner's own identity: the display name used whenever a
/// speaker is confirmed as "me". Existing profiles keep working through
/// aliases; changing the name here never rewrites past meetings.
enum MyProfilePreferences {
    static let displayNameKey = "damso.myDisplayName"

    static func displayName(_ defaults: UserDefaults = .standard) -> String {
        let raw = defaults.string(forKey: displayNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty { return raw }
        return Loc.tr("Me")
    }
}

/// The settings window: a fixed sidebar of sections on the left and one
/// scrolling pane on the right, replacing the previous toolbar tabs so long
/// panes (External Sync states, storage diagnostics) get room to breathe.
struct SettingsRootView: View {
    enum Section: String, CaseIterable, Identifiable {
        case general
        case agent
        case detection
        case externalSync
        case calendar
        case storage
        case models

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: Loc.tr("General")
            case .agent: Loc.tr("Summary agent")
            case .detection: Loc.tr("Meeting Detection")
            case .externalSync: Loc.tr("External Sync")
            case .calendar: Loc.tr("Calendar")
            case .storage: Loc.tr("Storage")
            case .models: Loc.tr("Local Models")
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .agent: "sparkles"
            case .detection: "waveform.and.person.filled"
            case .externalSync: "arrow.triangle.2.circlepath"
            case .calendar: "calendar.badge.plus"
            case .storage: "externaldrive"
            case .models: "waveform.badge.magnifyingglass"
            }
        }
    }

    @ObservedObject var sync: ExternalSyncController
    @ObservedObject var loginItem: LoginItemController
    @State private var selection: Section = .general
    @AppStorage(MyProfilePreferences.displayNameKey) private var displayName = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle()
                .fill(DamsoTokens.hairline)
                .frame(width: 1)
            detail
        }
        .background(DamsoTokens.canvas)
        .frame(minWidth: 800, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Section.allCases) { section in
                sidebarItem(section)
            }
            Spacer(minLength: DamsoTokens.spacing)
            profileCard
        }
        .padding(DamsoTokens.spacingSM)
        .frame(width: 224)
        .background(DamsoTokens.surfaceSoft)
    }

    private func sidebarItem(_ section: Section) -> some View {
        Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.body)
                    .frame(width: 20)
                Text(section.title)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(DamsoTokens.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                selection == section ? DamsoTokens.hairline : .clear,
                in: RoundedRectangle(cornerRadius: DamsoTokens.compactRadius)
            )
            .contentShape(RoundedRectangle(cornerRadius: DamsoTokens.compactRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == section ? .isSelected : [])
    }

    /// Bottom identity card: jumps to the General pane where the display
    /// name is edited, mirroring the account card of familiar settings UIs.
    private var profileCard: some View {
        Button {
            selection = .general
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(DamsoTokens.blockLilac.fillColor)
                    Text(profileInitial)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(DamsoTokens.blockLilac.inkColor)
                }
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(resolvedDisplayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(DamsoTokens.ink)
                        .lineLimit(1)
                    Text(Loc.tr("My Profile"))
                        .font(.caption)
                        .foregroundStyle(DamsoTokens.inkSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DamsoTokens.inkSecondary)
            }
            .padding(10)
            .contentShape(RoundedRectangle(cornerRadius: DamsoTokens.compactRadius))
        }
        .buttonStyle(.plain)
    }

    /// Reads the observed @AppStorage value so the card updates live while
    /// the name is edited in the General pane.
    private var resolvedDisplayName: String {
        let raw = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? Loc.tr("Me") : raw
    }

    private var profileInitial: String {
        String(resolvedDisplayName.prefix(1))
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .general: SettingsPane { GeneralSettingsView(loginItem: loginItem) }
        case .agent: SettingsPane { AgentSettingsView() }
        case .detection: SettingsPane { MeetingDetectionSettingsView() }
        case .externalSync: SettingsPane { ExternalSyncSettingsView(sync: sync) }
        case .calendar: SettingsPane { CalendarSettingsView() }
        case .storage: SettingsPane { StorageRootSettingsView() }
        case .models: SettingsPane { ModelSetupSettingsView() }
        }
    }
}

/// Shared scroll container for one settings pane.
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DamsoTokens.spacingXL) {
                content
            }
            .padding(.horizontal, DamsoTokens.spacingXL)
            .padding(.vertical, DamsoTokens.spacingLG)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DamsoTokens.canvas)
    }
}

/// A titled cluster of rows: large quiet header, hairline, then the rows.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title3)
                .foregroundStyle(DamsoTokens.inkSecondary)
                .padding(.bottom, DamsoTokens.spacingSM)
            Rectangle()
                .fill(DamsoTokens.hairline)
                .frame(height: 1)
            content
        }
    }
}

/// One label-left, control-right settings row with an optional subtitle.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: DamsoTokens.spacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(DamsoTokens.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(DamsoTokens.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DamsoTokens.spacingLG)
            control
        }
        .padding(.vertical, 14)
    }
}

extension SettingsRow where Control == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Quiet explanatory paragraph under a group's rows.
struct SettingsFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(DamsoTokens.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, DamsoTokens.spacingXS)
    }
}

/// General pane: identity, launch behavior, and language.
struct GeneralSettingsView: View {
    @ObservedObject var loginItem: LoginItemController
    @AppStorage(MyProfilePreferences.displayNameKey) private var displayName = ""
    @AppStorage(AgentPreferences.languageKey) private var languageSetting = SummaryLanguage.korean.rawValue

    var body: some View {
        SettingsGroup(title: Loc.tr("System")) {
            SettingsRow(title: Loc.tr("Launch at Login")) {
                Toggle("", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabledSafely($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!loginItem.canConfigure)
            }
            if let message = loginItem.configurationMessage {
                SettingsFootnote(text: message)
            }
        }
        .onAppear { loginItem.refresh() }

        SettingsGroup(title: Loc.tr("My Profile")) {
            SettingsRow(
                title: Loc.tr("Display name"),
                subtitle: Loc.tr("Used when you confirm a speaker as yourself: the meeting links to this person and their profile accumulates your meeting history, voice profile, and notes.")
            ) {
                TextField("", text: $displayName, prompt: Text(Loc.tr("Me")))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }
            SettingsFootnote(text: Loc.tr("Renaming here never rewrites past meetings. Keep old names as aliases on your profile so earlier confirmations still point to you."))
        }

        SettingsGroup(title: Loc.tr("Language")) {
            SettingsRow(
                title: Loc.tr("App and output language"),
                subtitle: Loc.tr("Applies to the interface and to generated summaries, titles, and person notes.")
            ) {
                Picker("", selection: $languageSetting) {
                    Text("한국어").tag(SummaryLanguage.korean.rawValue)
                    Text("English").tag(SummaryLanguage.english.rawValue)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}
