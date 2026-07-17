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

struct StorageRootSettingsView: View {
    @StateObject private var storage = StorageRootSettingsController()

    var body: some View {
        Form {
            Section(Loc.tr("Local Meeting Storage")) {
                Text(storage.rootPath)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Text(storage.statusMessage)
                    .foregroundStyle(storage.statusMessage == Loc.tr("Storage root is ready.") ? DamsoTokens.success : DamsoTokens.warning)
                HStack {
                    Button(Loc.tr("Check storage")) {
                        storage.refresh()
                    }
                    Button(Loc.tr("Choose storage folder"), systemImage: "folder") {
                        storage.chooseRoot()
                    }
                }
                if storage.requiresReopen {
                    Text(Loc.tr("Reopen Damso before starting another recording so the main window uses the selected root. Existing data was not moved."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 620)
    }
}
