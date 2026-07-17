import AVFoundation
import Foundation

enum WaveformSampler {
    static func samples(from url: URL, count: Int = 240) throws -> [Float] {
        guard count > 0 else { return [] }
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.commonFormat == .pcmFormatFloat32 else { return Array(repeating: 0.12, count: count) }
        let totalFrames = max(1, Int64(file.length))
        let capacity: AVAudioFrameCount = 8_192
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var peaks = Array(repeating: Float.zero, count: count)
        var frameOffset: Int64 = 0

        while frameOffset < totalFrames {
            try file.read(into: buffer, frameCount: capacity)
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let channels = buffer.floatChannelData else { break }
            for frame in 0..<frameLength {
                let absoluteFrame = frameOffset + Int64(frame)
                let bin = min(count - 1, Int(Double(absoluteFrame) / Double(totalFrames) * Double(count)))
                var peak = Float.zero
                for channel in 0..<Int(format.channelCount) {
                    peak = max(peak, abs(channels[channel][frame]))
                }
                peaks[bin] = max(peaks[bin], peak)
            }
            frameOffset += Int64(frameLength)
        }

        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return Array(repeating: 0.12, count: count) }
        return peaks.map { max(0.08, sqrt($0 / maximum)) }
    }
}

@MainActor
final class LocalAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var samples: [Float] = []
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?

    private var loadedURL: URL?
    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var waveformTask: Task<Void, Never>?

    func load(_ url: URL?) {
        guard loadedURL != url else { return }
        stop()
        waveformTask?.cancel()
        loadedURL = url
        samples = []
        currentTime = 0
        duration = 0
        errorMessage = nil
        guard let url else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            duration = player.duration
        } catch {
            errorMessage = "This audio format cannot be played on this Mac."
            return
        }
        waveformTask = Task {
            let result = await Task.detached(priority: .utility) {
                Result { try WaveformSampler.samples(from: url) }
            }.value
            guard !Task.isCancelled, loadedURL == url else { return }
            if case .success(let values) = result { samples = values }
        }
    }

    func toggle() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else if player.play() {
            isPlaying = true
            startTimer()
        }
    }

    func seek(to fraction: Double) {
        guard let player, duration > 0 else { return }
        player.currentTime = min(max(0, fraction), 1) * duration
        currentTime = player.currentTime
    }

    func skip(seconds: TimeInterval) {
        guard duration > 0 else { return }
        seek(to: (currentTime + seconds) / duration)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.currentTime = self.duration
            self.stopTimer()
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        if let progressTimer { RunLoop.main.add(progressTimer, forMode: .common) }
    }

    private func stopTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
}
