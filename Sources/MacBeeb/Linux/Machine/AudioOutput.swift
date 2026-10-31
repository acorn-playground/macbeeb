import BeebCore
import BeebHost
import CSDL3
import Foundation

/// Plays the emulator's sound, through SDL (and so PipeWire or PulseAudio).
/// SDL asks for samples; the callback just copies from the sample ring,
/// and the emulation thread keeps the ring topped up, so the sound card's
/// clock paces the emulation, as on the Mac.
final class AudioOutput {
    private let host: EmulatorHost
    private var stream: OpaquePointer?

    init(host: EmulatorHost) {
        self.host = host
    }

    deinit {
        if let stream { SDL_DestroyAudioStream(stream) }
    }

    func start() {
        guard SDLSubsystems.audio else {
            host.setAudioActive(false)
            return
        }
        if stream == nil {
            var spec = SDL_AudioSpec(format: SDL_AUDIO_F32, channels: 1, freq: Int32(host.sampleRate))
            // (SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK.)
            stream = SDL_OpenAudioDeviceStream(0xFFFF_FFFF, &spec, { data, stream, wanted, _ in
                guard let data, wanted > 0 else { return }
                let ring = Unmanaged<SampleRing>.fromOpaque(data).takeUnretainedValue()
                let count = Int(wanted) / MemoryLayout<Float>.size
                withUnsafeTemporaryAllocation(of: Float.self, capacity: count) { buffer in
                    _ = ring.read(into: buffer)
                    SDL_PutAudioStreamData(stream, buffer.baseAddress, wanted)
                }
            }, Unmanaged.passUnretained(host.audioRing).toOpaque())
            guard stream != nil else {
                NSLog("MacBeeb: no audio: \(String(cString: SDL_GetError()))")
                host.setAudioActive(false)
                return
            }
        }
        // Nothing's reading the ring while it's stopped.
        host.audioRing.discardAll()
        if SDL_ResumeAudioStreamDevice(stream) {
            host.setAudioActive(true)
        } else {
            NSLog("MacBeeb: no audio: \(String(cString: SDL_GetError()))")
            host.setAudioActive(false)
        }
    }

    func stop() {
        if let stream { SDL_PauseAudioStreamDevice(stream) }
        host.setAudioActive(false)
    }
}

/// SDL, for sound and game controllers (not its windows: GTK has those).
enum SDLSubsystems {
    /// Started once; whether sound is available.
    static let audio: Bool = {
        _ = started
        return SDL_WasInit(SDL_INIT_AUDIO) != 0
    }()

    static let gamepads: Bool = {
        _ = started
        return SDL_WasInit(SDL_INIT_GAMEPAD) != 0
    }()

    private static let started: Bool = {
        // GTK has the signals, and names the app to the sound server.
        SDL_SetHint(SDL_HINT_NO_SIGNAL_HANDLERS, "1")
        SDL_SetHint(SDL_HINT_APP_NAME, "MacBeeb")
        SDL_SetHint(SDL_HINT_AUDIO_DEVICE_STREAM_NAME, "BBC Micro")
        SDL_SetHint(SDL_HINT_AUDIO_DEVICE_STREAM_ROLE, "Game")
        // A small device buffer: the ring holds the rest.
        SDL_SetHint(SDL_HINT_AUDIO_DEVICE_SAMPLE_FRAMES, "512")
        _ = SDL_InitSubSystem(SDL_INIT_AUDIO)
        _ = SDL_InitSubSystem(SDL_INIT_GAMEPAD)
        return true
    }()
}
