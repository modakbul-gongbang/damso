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

/// Settings tab that makes "me" a first-class person: set the name your own
/// speaker confirmations should carry and see where it lands.
struct MyProfileSettingsView: View {
    @AppStorage(MyProfilePreferences.displayNameKey) private var displayName = ""

    var body: some View {
        Form {
            Section(Loc.tr("My Profile")) {
                TextField(Loc.tr("Display name"), text: $displayName, prompt: Text(Loc.tr("Me")))
                Text(Loc.tr("Used when you confirm a speaker as yourself: the meeting links to this person and their profile accumulates your meeting history, voice profile, and notes."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Text(Loc.tr("Renaming here never rewrites past meetings. Keep old names as aliases on your profile so earlier confirmations still point to you."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
