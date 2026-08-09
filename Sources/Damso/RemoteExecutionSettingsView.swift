import SwiftUI

/// Configures the two-machine split (R1-R13). Local is the default and needs
/// no setup at all; turning this on points detection and recording on this Mac
/// at another Mac that holds the canonical store and runs the heavy
/// processing. The only fact the owner has to supply is the SSH host - the
/// server's home directory, interpreter, store root, and every install step
/// are discovered or performed from here, with the Advanced fields left as an
/// override for an installation that was set up by hand.
@MainActor
final class RemoteExecutionSettingsController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        /// Preflight found something only the owner can fix on the server.
        case blocked
        /// Preflight found only fixable gaps; "Set up this Mac" can run.
        case needsSetup
        case provisioning
        /// Every step passed; the connection can be saved.
        case ready
    }

    @Published var isRemoteEnabled = false
    @Published var host = ""
    @Published var interpreterPath = ""
    @Published var storeRootPath = ""
    @Published var showsAdvanced = false
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var statuses: [RemoteSetupStep: RemoteSetupStatus] = [:]
    @Published private(set) var requiresReopen = false
    @Published private(set) var message = ""

    private let configuration: RemoteExecutionConfiguration
    private let service: RemoteSetupService
    private let localAppBundle: URL
    private var facts: RemoteServerFacts?

    init(
        configuration: RemoteExecutionConfiguration = RemoteExecutionConfiguration(),
        service: RemoteSetupService = RemoteSetupService(),
        localAppBundle: URL = RemoteSetupService.defaultLocalAppBundle()
    ) {
        self.configuration = configuration
        self.service = service
        self.localAppBundle = localAppBundle
        load()
    }

    var isConfigured: Bool {
        if case .remote = configuration.mode { true } else { false }
    }

    /// The checklist is only meaningful once a probe has actually run.
    var hasChecklist: Bool { !statuses.isEmpty }

    var isBusy: Bool { phase == .checking || phase == .provisioning }

    /// Only offered when every remaining gap is one the app can close itself -
    /// running it against a server still missing Homebrew Python would fail
    /// halfway through and leave a partial install behind.
    var canProvision: Bool {
        guard phase == .needsSetup else { return false }
        return true
    }

    var canSave: Bool { phase == .ready && !isBusy }

    private func load() {
        switch configuration.mode {
        case .local:
            isRemoteEnabled = false
            host = ""
            interpreterPath = ""
            storeRootPath = ""
        case .remote(let savedHost, let savedInterpreter):
            isRemoteEnabled = true
            host = savedHost
            interpreterPath = savedInterpreter
            storeRootPath = configuration.remoteStoreRootPath ?? ""
        }
    }

    // MARK: Intent

    func setRemoteEnabled(_ enabled: Bool) {
        isRemoteEnabled = enabled
        guard !enabled else { return }
        statuses = [:]
        phase = .idle
        facts = nil
        // Only a real saved connection needs tearing down; toggling off after
        // an exploratory probe should not announce a reopen that changes
        // nothing.
        guard isConfigured else {
            message = ""
            return
        }
        configuration.clearRemote()
        interpreterPath = ""
        storeRootPath = ""
        requiresReopen = true
        message = Loc.tr("This Mac owns its own local storage and processing again.")
    }

    /// Saves the probed connection. Only reachable once the checklist is fully
    /// green, so this never writes a configuration that has not been proven to
    /// work end to end - the failure mode the previous version of this pane
    /// had, where a typo'd host was saved and only surfaced later as a broken
    /// app on the next launch.
    func save() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInterpreter = interpreterPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStoreRoot = storeRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, trimmedInterpreter.hasPrefix("/"), trimmedStoreRoot.hasPrefix("/") else {
            message = Loc.tr("Enter the server's SSH host plus its absolute interpreter and store paths.")
            return
        }
        configuration.configureRemote(host: trimmedHost, interpreterPath: trimmedInterpreter, storeRootPath: trimmedStoreRoot)
        requiresReopen = true
        message = String(format: Loc.tr("Connected to %@."), trimmedHost)
    }

    // MARK: Preflight

    func runPreflight() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            message = Loc.tr("Enter the server's SSH host first.")
            return
        }
        phase = .checking
        message = ""
        statuses = [:]
        facts = nil
        Task { await performPreflight(host: trimmedHost) }
    }

    private func performPreflight(host: String) async {
        let service = self.service
        statuses[.connection] = .checking
        let outcome = await offMain { service.connect(host: host) }
        guard case .connected(let discovered) = outcome else {
            if case .unavailable(let status) = outcome {
                statuses[.connection] = status
            }
            phase = .blocked
            return
        }
        // mlx-whisper is Apple's MLX runtime, so transcription cannot run on
        // anything but Apple Silicon at all - better to say so here than to
        // install several gigabytes and fail on the first meeting.
        guard discovered.isAppleSilicon else {
            statuses[.connection] = .missing(Loc.tr("This Mac is not Apple Silicon; local transcription cannot run there."))
            phase = .blocked
            return
        }
        facts = discovered
        statuses[.connection] = .satisfied(discovered.home)
        applyDiscoveredDefaults(discovered)

        statuses[.basePython] = service.checkBasePython(facts: discovered)

        statuses[.ffmpeg] = .checking
        statuses[.ffmpeg] = await offMain { service.checkFfmpeg(host: host) }

        let storeRoot = storeRootPath
        statuses[.store] = .checking
        statuses[.store] = await offMain { service.checkStore(host: host, storeRoot: storeRoot) }

        let interpreter = interpreterPath
        statuses[.environment] = .checking
        statuses[.environment] = await offMain { service.checkEnvironment(host: host, interpreterPath: interpreter) }

        // Asking a missing interpreter about models only ever returns the same
        // "missing" it already reported; skip the round trip and say why.
        if statuses[.environment]?.isSatisfied == true {
            let modelRoot = RemoteServerLayout.modelRoot(home: discovered.home)
            statuses[.models] = .checking
            statuses[.models] = await offMain {
                service.checkModels(host: host, interpreterPath: interpreter, modelRoot: modelRoot)
            }
        } else {
            statuses[.models] = .missing(Loc.tr("Waiting for the processing environment."))
        }

        let home = discovered.home
        statuses[.app] = .checking
        statuses[.app] = await offMain { service.checkApp(host: host, home: home) }

        statuses[.launchAgent] = .checking
        statuses[.launchAgent] = await offMain { service.checkLaunchAgent(host: host, home: home) }

        phase = resolvedPhase()
    }

    /// Fills the Advanced fields from what the server reported, without ever
    /// overwriting a value the owner set themselves - an installation made by
    /// hand before this flow existed keeps its own interpreter and store root,
    /// and is validated as-is rather than being migrated behind their back.
    private func applyDiscoveredDefaults(_ discovered: RemoteServerFacts) {
        if interpreterPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            interpreterPath = RemoteServerLayout.virtualenvPython(home: discovered.home)
        }
        if storeRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            storeRootPath = RemoteServerLayout.defaultStoreRoot(home: discovered.home)
        }
    }

    private func resolvedPhase() -> Phase {
        let unsatisfied = RemoteSetupStep.allCases.filter { statuses[$0]?.isSatisfied != true }
        if unsatisfied.isEmpty { return .ready }
        if unsatisfied.contains(where: { !$0.isProvisionable }) { return .blocked }
        return .needsSetup
    }

    // MARK: Provisioning

    func provision() {
        guard canProvision, let discovered = facts else { return }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        phase = .provisioning
        message = ""
        Task { await performProvisioning(host: trimmedHost, facts: discovered) }
    }

    /// Runs the fixable steps in dependency order, stopping at the first
    /// failure: the app cannot be signed before it is copied, and the
    /// LaunchAgent must not be started pointing at an interpreter whose
    /// packages failed to install - a started-but-broken service is exactly
    /// the silent-failure shape this whole flow exists to prevent.
    private func performProvisioning(host: String, facts discovered: RemoteServerFacts) async {
        let service = self.service
        let home = discovered.home
        let interpreter = interpreterPath

        if statuses[.environment]?.isSatisfied != true {
            statuses[.environment] = .working(Loc.tr("Installing processing packages. This can take several minutes."))
            let result = await offMain { service.provisionEnvironment(host: host, facts: discovered) }
            statuses[.environment] = result
            guard result.isSatisfied else { return finishProvisioning() }
            // Provisioning always builds its own virtualenv, so the saved
            // interpreter must follow it there.
            interpreterPath = RemoteServerLayout.virtualenvPython(home: home)
        }
        let resolvedInterpreter = interpreterPath.isEmpty ? interpreter : interpreterPath

        if statuses[.models]?.isSatisfied != true {
            statuses[.models] = .working(Loc.tr("Downloading transcription and diarization models. This can take a while."))
            let result = await offMain {
                service.provisionModels(host: host, home: home, interpreterPath: resolvedInterpreter)
            }
            statuses[.models] = result
            guard result.isSatisfied else { return finishProvisioning() }
        }

        if statuses[.app]?.isSatisfied != true {
            statuses[.app] = .working(Loc.tr("Copying Damso to the server."))
            let bundle = localAppBundle
            let result = await offMain { service.provisionApp(host: host, home: home, localAppBundle: bundle) }
            statuses[.app] = result
            guard result.isSatisfied else { return finishProvisioning() }
        }

        if statuses[.launchAgent]?.isSatisfied != true {
            statuses[.launchAgent] = .working(Loc.tr("Registering the background service."))
            let result = await offMain {
                service.provisionLaunchAgent(host: host, home: home, interpreterPath: resolvedInterpreter)
            }
            statuses[.launchAgent] = result
            guard result.isSatisfied else { return finishProvisioning() }
        }

        finishProvisioning()
    }

    private func finishProvisioning() {
        phase = resolvedPhase()
        if phase == .ready {
            message = Loc.tr("This server is ready. Save to start using it.")
        }
    }

    private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: work).value
    }
}

struct RemoteExecutionSettingsView: View {
    @StateObject private var settings = RemoteExecutionSettingsController()

    var body: some View {
        SettingsGroup(title: Loc.tr("Server Mac")) {
            SettingsRow(
                title: Loc.tr("Use another Mac for storage and processing"),
                subtitle: Loc.tr("This Mac keeps detecting and recording meetings. The server holds every recording and runs transcription, so your laptop stays free and meetings finish processing even when it is closed.")
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.isRemoteEnabled },
                    set: { settings.setRemoteEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(settings.isBusy)
            }

            if settings.isRemoteEnabled {
                SettingsRow(
                    title: Loc.tr("SSH host"),
                    subtitle: Loc.tr("The name you use with ssh, for example a ~/.ssh/config alias. Key-based login must already work from Terminal.")
                ) {
                    HStack(spacing: 12) {
                        TextField("", text: $settings.host, prompt: Text("mini"))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .disabled(settings.isBusy)
                            .onSubmit { settings.runPreflight() }
                        Button(Loc.tr("Check")) {
                            settings.runPreflight()
                        }
                        .disabled(settings.isBusy || settings.host.isEmpty)
                    }
                }

                if settings.hasChecklist {
                    checklist
                    actions
                }

                advanced
            }
        }

        if !settings.message.isEmpty {
            SettingsFootnote(text: settings.message)
        }
        if settings.requiresReopen {
            SettingsFootnote(text: Loc.tr("Reopen Damso for this change to take effect. Existing data on either machine is untouched."))
        }
        if !settings.isRemoteEnabled {
            SettingsFootnote(text: Loc.tr("Leave this off to keep detection, recording, storage, and processing all on this Mac."))
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RemoteSetupStep.allCases) { step in
                if let status = settings.statuses[step] {
                    checklistRow(step, status)
                }
            }
        }
        .padding(.vertical, DamsoTokens.spacingXS)
    }

    private func checklistRow(_ step: RemoteSetupStep, _ status: RemoteSetupStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol(for: status))
                .font(.body)
                .foregroundStyle(color(for: status))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.body)
                    .foregroundStyle(DamsoTokens.ink)
                if !status.detail.isEmpty {
                    Text(status.detail)
                        .font(.footnote)
                        .foregroundStyle(DamsoTokens.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Only the steps the owner has to fix themselves explain how;
                // the rest are handled by the setup button below.
                if !status.isSatisfied, !status.isBusy, !step.isProvisionable, !step.manualHint.isEmpty {
                    Text(step.manualHint)
                        .font(.footnote)
                        .foregroundStyle(DamsoTokens.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            if settings.phase == .provisioning || settings.phase == .checking {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            if settings.canProvision {
                Button(Loc.tr("Set up this Mac"), systemImage: "arrow.down.circle") {
                    settings.provision()
                }
                .buttonStyle(.borderedProminent)
            }
            // Setup is the prominent call to action while gaps remain, so
            // saving stays quiet until it is actually the next thing to do.
            Button(Loc.tr("Save and use this Mac")) {
                settings.save()
            }
            .buttonStyle(.bordered)
            .disabled(!settings.canSave)
        }
        .padding(.vertical, DamsoTokens.spacingXS)
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                settings.showsAdvanced.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: settings.showsAdvanced ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                    Text(Loc.tr("Advanced"))
                        .font(.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DamsoTokens.inkSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, DamsoTokens.spacingXS)

            if settings.showsAdvanced {
                SettingsRow(
                    title: Loc.tr("Python interpreter path"),
                    subtitle: Loc.tr("Absolute path on the server. Filled in by setup; change it only to reuse an interpreter you installed yourself.")
                ) {
                    TextField("", text: $settings.interpreterPath, prompt: Text("/opt/homebrew/bin/python3.12"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .disabled(settings.isBusy)
                }
                SettingsRow(
                    title: Loc.tr("Store root path"),
                    subtitle: Loc.tr("Absolute path on the server where the canonical store lives. Copy your store there before setup; Damso never moves it for you.")
                ) {
                    TextField("", text: $settings.storeRootPath, prompt: Text("/Users/<name>/Library/Application Support/Damso"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .disabled(settings.isBusy)
                }
            }
        }
    }

    private func symbol(for status: RemoteSetupStatus) -> String {
        switch status {
        case .satisfied: "checkmark.circle.fill"
        case .missing: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        case .unknown, .checking, .working: "arrow.triangle.2.circlepath"
        }
    }

    private func color(for status: RemoteSetupStatus) -> Color {
        switch status {
        case .satisfied: DamsoTokens.success
        case .missing: DamsoTokens.warning
        case .failed: DamsoTokens.critical
        case .unknown, .checking, .working: DamsoTokens.accent
        }
    }
}
