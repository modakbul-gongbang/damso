import AppKit
import SwiftUI

@MainActor
final class StorageRootSettingsController: ObservableObject {
    @Published private(set) var rootPath = ""
    @Published private(set) var statusMessage = ""
    @Published private(set) var requiresReopen = false

    private let configuration: StorageRootConfiguration

    init(configuration: StorageRootConfiguration = StorageRootConfiguration()) {
        self.configuration = configuration
        refresh()
    }

    var isHealthy: Bool {
        statusMessage == Loc.tr("Storage root is ready.")
    }

    func refresh() {
        rootPath = configuration.rootURL.path
        statusMessage = description(for: configuration.health())
    }

    func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = Loc.tr("Use this folder")
        panel.message = Loc.tr("Damso will create and use its canonical Plaud folder structure inside this local folder. Existing data is never moved automatically.")
        panel.directoryURL = configuration.rootURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try configuration.select(root: url)
            requiresReopen = true
            refresh()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func description(for health: StorageHealth) -> String {
        switch health {
        case .ready:
            Loc.tr("Storage root is ready.")
        case .readOnly:
            Loc.tr("Storage root is read-only. Choose a writable local folder.")
        case let .insufficientSpace(availableBytes):
            String(format: Loc.tr("Storage root has insufficient free space (%d bytes available)."), availableBytes)
        case let .unsupportedSchema(found):
            String(format: Loc.tr("Storage root uses unsupported schema version %d."), found)
        case let .unavailable(message):
            message
        }
    }
}

/// Pane for the canonical store root plus the derived search index, which
/// lives here because the index is a property of the store, not the agent.
struct StorageRootSettingsView: View {
    @StateObject private var storage = StorageRootSettingsController()
    @State private var isRebuildingIndex = false
    @State private var indexMessage: String?

    var body: some View {
        SettingsGroup(title: Loc.tr("Local Meeting Storage")) {
            SettingsRow(title: Loc.tr("Storage folder"), subtitle: storage.rootPath) {
                Button(Loc.tr("Choose storage folder"), systemImage: "folder") {
                    storage.chooseRoot()
                }
            }
            SettingsRow(title: storage.statusMessage) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(storage.isHealthy ? DamsoTokens.success : DamsoTokens.warning)
                        .frame(width: 8, height: 8)
                    Button(Loc.tr("Check storage")) {
                        storage.refresh()
                    }
                }
            }
            if storage.requiresReopen {
                SettingsFootnote(text: Loc.tr("Reopen Damso before starting another recording so the main window uses the selected root. Existing data was not moved."))
            }
        }

        SettingsGroup(title: Loc.tr("Search index")) {
            SettingsRow(
                title: Loc.tr("Rebuild search index"),
                subtitle: Loc.tr("The SQLite index is derived from your local meeting files and can always be rebuilt from them. Rebuilding never changes a meeting file.")
            ) {
                Button(isRebuildingIndex ? Loc.tr("Rebuilding...") : Loc.tr("Rebuild")) {
                    rebuildIndex()
                }
                .disabled(isRebuildingIndex)
            }
            if let indexMessage {
                Text(indexMessage)
                    .font(.damsoMonoCaption)
                    .foregroundStyle(DamsoTokens.inkSecondary)
                    .padding(.vertical, DamsoTokens.spacingXS)
            }
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
