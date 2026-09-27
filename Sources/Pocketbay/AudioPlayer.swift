import AVFoundation
import os

private let log = Logger(subsystem: "com.devesh.pocketbay", category: "audio")

/// Plays Android's audio on the Mac's current output device. AVAudioEngine binds to the
/// default output when it starts, so on every device change we restart it: sound follows
/// whatever is picked in Control Center, even mid-game. (The emulator's own CoreAudio
/// output binds once at launch and never follows.)
final class AudioPlayer: @unchecked Sendable {
    static let sampleRate = 48_000.0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioPlayer.sampleRate, channels: 2)!
    private let queue = DispatchQueue(label: "pocketbay.audio")
    private var scheduledFrames = 0          // frames queued but not yet played
    private var observer: NSObjectProtocol?

    /// Keep latency low: drop audio if more than this is queued (e.g. after a hiccup).
    private let maxQueuedFrames = Int(AudioPlayer.sampleRate * 0.12)

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { [weak self] _ in
            self?.queue.async { self?.restart() }
        }
        queue.async { self.restart() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        engine.stop()
    }

    /// (Re)binds to the current default output device.
    private func restart() {
        player.stop()
        engine.stop()
        scheduledFrames = 0
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.play()
            log.info("audio output started")
        } catch {
            log.error("audio engine failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Queue interleaved stereo S16 PCM from the emulator.
    func enqueue(_ pcm: Data) {
        queue.async { self.schedule(pcm) }
    }

    private func schedule(_ pcm: Data) {
        guard engine.isRunning else { return }
        let frames = pcm.count / 4
        guard frames > 0, scheduledFrames + frames <= maxQueuedFrames,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                left[i] = Float(Int16(littleEndian: s[2 * i])) / 32768
                right[i] = Float(Int16(littleEndian: s[2 * i + 1])) / 32768
            }
        }
        scheduledFrames += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
            self?.queue.async { self?.scheduledFrames -= frames }
        }
    }
}
