import AVFoundation
import BeebCore
import BeebHost

/// Plays the emulator's sound. The render callback just copies from the
/// sample ring; the emulation thread keeps the ring topped up, so the audio
/// device's clock paces the emulation.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private let host: EmulatorHost

    init(host: EmulatorHost) {
        self.host = host
    }

    /// The engine's source, made once: starting again (a network station
    /// heard again) reuses it, rather than adding a second reader of the
    /// ring, which would drain it twice as fast.
    private var source: AVAudioSourceNode?

    func start() {
        if source == nil {
            let ring = host.audioRing
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(host.sampleRate), channels: 1) else { return }
            let node = AVAudioSourceNode(format: format) { _, _, frameCount, buffers -> OSStatus in
                let list = UnsafeMutableAudioBufferListPointer(buffers)
                guard let data = list[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                _ = ring.read(into: UnsafeMutableBufferPointer(start: data, count: Int(frameCount)))
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            source = node
        }
        guard !engine.isRunning else { return }
        // Nothing's reading the ring while the engine's stopped.
        host.audioRing.discardAll()
        do {
            try engine.start()
            host.setAudioActive(true)
        } catch {
            NSLog("MacBeeb: no audio: \(error)")
            host.setAudioActive(false)
        }
    }

    func stop() {
        engine.stop()
        host.setAudioActive(false)
    }
}
