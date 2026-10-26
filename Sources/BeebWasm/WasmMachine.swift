// A BBC Micro as the WebAssembly exports (Exports.swift) see it: BeebCore's
// BBCMicro, its TV, and the ROMs it's built from, which the host supplies
// (BeebROMs isn't part of the WebAssembly build).
//
// Nothing here emulates anything: it's bookkeeping between the flat ABI and
// the machine.

import BeebCore
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

final class WasmMachine {
    var configuration: BBCMicro.Configuration
    private(set) var machine: BBCMicro?
    let tv = TVOutput()
    /// The Master's clock at power on (the host's choice, so that runs
    /// repeat exactly; otherwise 2000-01-01 00:00:00, a Saturday).
    var rtc = RTCTime(year: 0, month: 1, day: 1, dayOfWeek: 7, hours: 0, minutes: 0, seconds: 0)

    /// The last frame as RGBA8, converted when it's asked for.
    let rgba: UnsafeMutablePointer<UInt32>
    private var rgbaFrame = -1

    struct RTCTime {
        var year, month, day, dayOfWeek, hours, minutes, seconds: Int
    }

    init(model: BBCMicro.Model) {
        configuration = BBCMicro.Configuration(model: model, os: [], sidewaysROMs: [:])
        rgba = .allocate(capacity: TVOutput.width * TVOutput.height)
        rgba.initialize(repeating: 0xFF00_0000, count: TVOutput.width * TVOutput.height)
    }

    deinit {
        rgba.deallocate()
    }

    /// Builds the machine afresh from the configuration (a power cycle),
    /// keeping the discs in the drives.
    func powerOn() {
        let old = machine
        let new = BBCMicro(configuration: configuration)
        new.rtc.setTime(year: rtc.year, month: rtc.month, dayOfMonth: rtc.day, dayOfWeek: rtc.dayOfWeek,
                        hours: rtc.hours, minutes: rtc.minutes, seconds: rtc.seconds)
        if let old { new.insertDiscs(from: old) }
        install(new)
    }

    /// Replaces the machine with one restored from a save state.
    func restore(_ file: SaveStateFile) throws {
        let new = try file.makeMachine()
        configuration = file.configuration
        install(new)
    }

    private func install(_ new: BBCMicro) {
        machine?.tv = nil
        new.tv = tv
        machine = new
    }

    /// The last complete frame, RGBA8 (bytes R, G, B, 255), top row first.
    func frameRGBA() -> UnsafeMutablePointer<UInt32> {
        if rgbaFrame != tv.frameCount {
            rgbaFrame = tv.frameCount
            tv.lastFrame.withUnsafeBufferPointer { frame in
                for i in frame.indices {
                    // 0x00RRGGBB to little-endian RGBA.
                    let v = frame[i]
                    rgba[i] = 0xFF00_0000 | (v & 0xFF) << 16 | (v & 0xFF00) | (v >> 16 & 0xFF)
                }
            }
        }
        return rgba
    }

    /// FNV-1a over the last frame's pixels (0x00RRGGBB): the same frame
    /// gives the same hash on every host.
    func frameHash() -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        tv.lastFrame.withUnsafeBufferPointer { frame in
            for v in frame {
                for shift in stride(from: 0, to: 32, by: 8) {
                    hash = (hash ^ (v >> UInt32(shift) & 0xFF)) &* 0x0100_0193
                }
            }
        }
        return hash
    }
}
