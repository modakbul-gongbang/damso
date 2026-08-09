import Foundation

struct LocalModelSetupCommand: Equatable, Sendable {
    let pythonExecutable: String
    let modelRoot: URL
    let install: Bool

    init(
        pythonExecutable: String = "python3",
        modelRoot: URL = LocalModelSetupCommand.defaultModelRoot(),
        install: Bool
    ) {
        self.pythonExecutable = pythonExecutable
        self.modelRoot = modelRoot.standardizedFileURL
        self.install = install
    }

    var arguments: [String] {
        [
            pythonExecutable,
            "-m",
            "damso.model_setup",
            install ? "--install" : "--status",
            "--model-root",
            modelRoot.path,
        ]
    }

    static func defaultModelRoot(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Damso/Models", isDirectory: true)
    }
}

struct LocalModelSetupResult: Codable, Equatable, Sendable {
    let ok: Bool
    let whisperReady: Bool?
    let sherpaReady: Bool?
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case whisperReady = "whisper_ready"
        case sherpaReady = "sherpa_ready"
        case errorCode = "error_code"
    }
}

enum LocalModelSetupState: Equatable {
    case unchecked
    case checking
    case unavailable(String)
    case ready
    case installing
    case failed(String)

    var title: String {
        switch self {
        case .unchecked, .checking:
            Loc.tr("Checking local processing models")
        case .unavailable:
            Loc.tr("Local processing models are not installed")
        case .ready:
            Loc.tr("Local processing models are ready")
        case .installing:
            Loc.tr("Installing local processing models")
        case .failed:
            Loc.tr("Local processing model setup failed")
        }
    }
}

enum LocalModelSetupProcessRunner {
    private static let unavailable = LocalModelSetupResult(ok: false, whisperReady: nil, sherpaReady: nil, errorCode: "model_setup_unavailable")

    static func run(_ command: LocalModelSetupCommand, launcher: CommandLauncher = CommandLauncher()) -> LocalModelSetupResult {
        let argv: [String]
        switch launcher.configuration.mode {
        case .local:
            argv = command.arguments
        case .remote:
            argv = launcher.argv(module: "damso.model_setup", moduleArguments: Array(command.arguments.dropFirst(3)))
        }
        let inherited = ProcessInfo.processInfo.environment
        let environment = [
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "PATH": inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]

        do {
            let output = try launcher.run(argv: argv, environment: environment, maximumResponseBytes: 64 * 1_024)
            return (try? JSONDecoder().decode(LocalModelSetupResult.self, from: output.data)) ?? unavailable
        } catch {
            return unavailable
        }
    }
}

@MainActor
final class LocalModelSetupController: ObservableObject {
    @Published private(set) var state: LocalModelSetupState = .unchecked

    func refresh() {
        state = .checking
        let command = LocalModelSetupCommand(install: false)
        Task {
            let result = await Task.detached(priority: .utility) {
                LocalModelSetupProcessRunner.run(command)
            }.value
            apply(result, installing: false)
        }
    }

    func install() {
        state = .installing
        let command = LocalModelSetupCommand(install: true)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                LocalModelSetupProcessRunner.run(command)
            }.value
            apply(result, installing: true)
        }
    }

    private func apply(_ result: LocalModelSetupResult, installing: Bool) {
        if result.ok && result.whisperReady == true && result.sherpaReady == true {
            state = .ready
            return
        }
        let code = result.errorCode ?? (installing ? "model_install_incomplete" : "models_not_installed")
        state = installing ? .failed(code) : .unavailable(code)
    }
}
