@preconcurrency import AVFoundation
@preconcurrency import ScreenCaptureKit
import CoreGraphics
import Foundation

enum RecordingPermissionState: Equatable {
    case ready
    case microphoneDenied
    case screenRecordingDenied
}

enum LocalRecordingError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case microphonePermissionDenied
    case screenRecordingPermissionDenied
    case noDisplayAvailable
    case systemAudioWriterFailed

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "There is no active recording."
        case .microphonePermissionDenied: "Microphone permission is required to start a meeting recording."
        case .screenRecordingPermissionDenied: "Screen Recording permission is required to capture system audio."
        case .noDisplayAvailable: "No display is available for system audio capture."
        case .systemAudioWriterFailed: "System audio could not be written safely."
        }
    }
}

struct CapturedAudioFiles: Equatable {
    let microphone: URL
    let systemAudio: URL
}

@MainActor
protocol RecordingCapture: AnyObject {
    func permissionState() async -> RecordingPermissionState
    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles
    func stop() async throws -> CapturedAudioFiles
}

enum RecordingSessionState: Equatable {
    case idle
    case checkingPermissions
    case recording(CapturedAudioFiles)
    case blocked(RecordingPermissionState)
    case stopping
    case stopped(CapturedAudioFiles)
    case failed

    var allowsHintEditing: Bool {
        switch self {
        case .idle, .recording, .stopped, .failed, .blocked:
            true
        case .checkingPermissions, .stopping:
            false
        }
    }
}

enum RecordingSessionError: Error, Equatable {
    case alreadyActive
    case permissionRequired(RecordingPermissionState)
    case notActive
}

/// Keeps the immediate capture action independent from optional meeting hints.
/// UI layers can bind this state without receiving raw audio buffers or secrets.
@MainActor
final class RecordingSessionController: ObservableObject {
    @Published private(set) var state: RecordingSessionState = .idle
    @Published private(set) var hints: MeetingHints = .empty
    @Published private(set) var lastError: String?

    private let capture: RecordingCapture
    private let recoveryJournal: RecordingRecoveryJournal?

    init(capture: RecordingCapture, recoveryJournal: RecordingRecoveryJournal? = nil) {
        self.capture = capture
        self.recoveryJournal = recoveryJournal
    }

    var recoveryAction: String? {
        switch state {
        case .blocked(.microphoneDenied):
            "Allow Microphone access in System Settings, then try recording again."
        case .blocked(.screenRecordingDenied):
            "Allow Screen Recording access in System Settings to capture system audio, then try again."
        case .failed:
            "Keep the recorded files, review the local error, and retry the failed action."
        default:
            nil
        }
    }

    func startNow(in recordingDirectory: URL) async throws -> CapturedAudioFiles {
        guard case .recording = state else {
            if case .checkingPermissions = state { throw RecordingSessionError.alreadyActive }
            if case .stopping = state { throw RecordingSessionError.alreadyActive }
            return try await begin(in: recordingDirectory)
        }
        throw RecordingSessionError.alreadyActive
    }

    func updateHints(_ newHints: MeetingHints) {
        guard state.allowsHintEditing else { return }
        hints = newHints
    }

    func stop() async throws -> CapturedAudioFiles {
        guard case .recording = state else { throw RecordingSessionError.notActive }
        state = .stopping
        do {
            let files = try await capture.stop()
            try recoveryJournal?.stop(files: files)
            state = .stopped(files)
            return files
        } catch {
            try? recoveryJournal?.markFailure(code: "recording_stop_failed")
            lastError = error.localizedDescription
            state = .failed
            throw error
        }
    }

    private func begin(in recordingDirectory: URL) async throws -> CapturedAudioFiles {
        state = .checkingPermissions
        let permission = await capture.permissionState()
        guard permission == .ready else {
            state = .blocked(permission)
            throw RecordingSessionError.permissionRequired(permission)
        }
        do {
            let files = try await capture.start(in: recordingDirectory)
            do {
                try recoveryJournal?.begin(files: files)
            } catch {
                _ = try? await capture.stop()
                try? recoveryJournal?.markFailure(code: "recording_checkpoint_unavailable")
                throw error
            }
            state = .recording(files)
            lastError = nil
            return files
        } catch {
            try? recoveryJournal?.markFailure(code: "recording_start_failed")
            lastError = error.localizedDescription
            state = .failed
            throw error
        }
    }
}

@MainActor
final class LocalRecordingCoordinator: NSObject, ObservableObject, RecordingCapture {
    @Published private(set) var isRecording = false
    @Published private(set) var lastError: String?

    private var microphoneRecorder: AVAudioRecorder?
    private var systemAudioRecorder: SystemAudioRecorder?
    private(set) var files: CapturedAudioFiles?

    func permissionState() async -> RecordingPermissionState {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphoneAllowed: Bool
        switch microphone {
        case .authorized:
            microphoneAllowed = true
        case .notDetermined:
            microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        default:
            microphoneAllowed = false
        }
        guard microphoneAllowed else { return .microphoneDenied }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            return .screenRecordingDenied
        }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return .ready
        } catch {
            return .screenRecordingDenied
        }
    }

    func start(in recordingDirectory: URL) async throws -> CapturedAudioFiles {
        guard !isRecording else { throw LocalRecordingError.alreadyRecording }
        let permissions = await permissionState()
        switch permissions {
        case .ready:
            break
        case .microphoneDenied:
            throw LocalRecordingError.microphonePermissionDenied
        case .screenRecordingDenied:
            throw LocalRecordingError.screenRecordingPermissionDenied
        }

        try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
        let microphoneURL = recordingDirectory.appendingPathComponent("microphone.caf")
        let systemURL = recordingDirectory.appendingPathComponent("system-audio.m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatAppleIMA4,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
        let microphone = try AVAudioRecorder(url: microphoneURL, settings: settings)
        microphone.isMeteringEnabled = true
        guard microphone.record() else { throw LocalRecordingError.microphonePermissionDenied }

        let systemAudio = SystemAudioRecorder()
        do {
            try await systemAudio.start(outputURL: systemURL)
        } catch {
            microphone.stop()
            throw error
        }

        microphoneRecorder = microphone
        systemAudioRecorder = systemAudio
        let files = CapturedAudioFiles(microphone: microphoneURL, systemAudio: systemURL)
        self.files = files
        isRecording = true
        lastError = nil
        return files
    }

    func stop() async throws -> CapturedAudioFiles {
        guard isRecording, let microphone = microphoneRecorder, let systemAudio = systemAudioRecorder, let files else {
            throw LocalRecordingError.notRecording
        }
        microphone.stop()
        do {
            try await systemAudio.stop()
        } catch {
            lastError = error.localizedDescription
            isRecording = false
            microphoneRecorder = nil
            systemAudioRecorder = nil
            throw error
        }
        isRecording = false
        microphoneRecorder = nil
        systemAudioRecorder = nil
        return files
    }
}

final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputQueue = DispatchQueue(label: "damso.system-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var streamError: Error?

    func start(outputURL: URL) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw LocalRecordingError.noDisplayAvailable }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .audio) else {
            throw LocalRecordingError.systemAudioWriterFailed
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        guard writer.canAdd(input) else { throw LocalRecordingError.systemAudioWriterFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? LocalRecordingError.systemAudioWriterFailed }
        writer.startSession(atSourceTime: .zero)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
        self.writer = writer
        self.writerInput = input
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async throws {
        let (activeStream, activeWriter, activeWriterInput) = lock.withLock { (stream, writer, writerInput) }
        guard let activeStream, let activeWriter, let activeWriterInput else { throw LocalRecordingError.notRecording }
        try await activeStream.stopCapture()
        activeWriterInput.markAsFinished()
        await withCheckedContinuation { continuation in
            activeWriter.finishWriting {
                continuation.resume()
            }
        }
        let capturedError = lock.withLock { () -> Error? in
            let error = streamError
            self.stream = nil
            self.writer = nil
            self.writerInput = nil
            return error
        }
        if let capturedError { throw capturedError }
        guard activeWriter.status == .completed else { throw activeWriter.error ?? LocalRecordingError.systemAudioWriterFailed }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let writerInput, writerInput.isReadyForMoreMediaData else { return }
        writerInput.append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        defer { lock.unlock() }
        streamError = error
    }
}
