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

/// Local models are entirely the server machine's concern now (D-05/D-11: a
/// single `damso-server` daemon owns processing, local or remote, and
/// `make install-server`/`make install-local-models` manage its models).
/// This Settings panel only ever makes sense on the machine that will run
/// `make install-server` - a plain local `Process` spawn, never routed
/// through the HTTP client or any remote transport.
enum LocalModelSetupProcessRunner {
    private static let unavailable = LocalModelSetupResult(ok: false, whisperReady: nil, sherpaReady: nil, errorCode: "model_setup_unavailable")

    static func run(_ command: LocalModelSetupCommand) -> LocalModelSetupResult {
        let inherited = ProcessInfo.processInfo.environment
        let environment = [
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "PATH": inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command.arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return unavailable
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return unavailable }
        return (try? JSONDecoder().decode(LocalModelSetupResult.self, from: data)) ?? unavailable
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
