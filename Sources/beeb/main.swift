// beeb: run a headless BBC Micro from the command line.
//
//   beeb [--load DISC.ssd:FILE] [--seconds N] [--type TEXT] [--screenshot FILE.png] [--text]
//        [--record FILE.mp4|.mov [--codec h264|hevc|proRes] [--drive-sounds]] [--disc FILE.ssd|.dsd [--boot]]
//        [--model-a | --master | --bplus | --compact] [--tube | --z80 | --512 | --arm | --turbo] [--tape FILE.uef|.csw]
//        [--hard-disc FILE.dat] [--rom BANK:FILE.rom] [--station N]
//
// Boots a Model B (OS 1.2, BASIC 2) or with --master a Master 128 (with --z80 or --512 booting the
// bundled CP/M or DOS Plus disc, unless --disc gives another), types TEXT (with \n for Return), runs
// for N seconds of emulated time after typing finishes (default 3), then
// writes a screenshot and/or prints the Mode 7 screen text.

import BeebCapture
import BeebCore
import BeebROMs
import Foundation

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: beeb [--seconds N] [--type TEXT] [--screenshot FILE.png] [--text]\n".utf8))
    exit(2)
}

var seconds = 3.0
var typeText: String?
var screenshotPath: String?
var printText = false
var printPCs = false
var traceCount = 0
var loads: [(disc: String, file: String)] = []
var recordPath: String?
var discPath: String?
var shiftBreak = false
var codec = VideoRecorder.Codec.h264
var model = BBCMicro.Model.modelB
var tapePath: String?
var secondProcessor = false
var coprocessor = BBCMicro.Coprocessor.mos6502
var driveSounds = false
var hardDiscPath: String?
var extraROMs: [Int: [UInt8]] = [:]
var econetStation: Int?

var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--seconds":
        guard let value = arguments.popFirst().flatMap(Double.init) else { usage() }
        seconds = value
    case "--type":
        guard let value = arguments.popFirst() else { usage() }
        typeText = value.replacingOccurrences(of: "\\n", with: "\n")
    case "--screenshot":
        guard let value = arguments.popFirst() else { usage() }
        screenshotPath = value
    case "--load":
        // DISC.ssd:FILE - load a file from a disc image into memory.
        guard let value = arguments.popFirst(), let colon = value.lastIndex(of: ":") else { usage() }
        loads.append((String(value[..<colon]), String(value[value.index(after: colon)...])))
    case "--disc":
        guard let value = arguments.popFirst() else { usage() }
        discPath = value
    case "--boot":
        shiftBreak = true
    case "--station":
        // An Econet module, as this station (with no network on it).
        guard let value = arguments.popFirst().flatMap(Int.init) else { usage() }
        econetStation = value
    case "--rom":
        // A sideways ROM in a bank, in place of what's there.
        guard let value = arguments.popFirst(), let colon = value.firstIndex(of: ":"), let bank = Int(value[..<colon]),
              let data = FileManager.default.contents(atPath: String(value[value.index(after: colon)...])) else { usage() }
        extraROMs[bank] = [UInt8](data)
    case "--hard-disc":
        // A SCSI hard disc (with its .dsc beside it, if there is one).
        guard let value = arguments.popFirst() else { usage() }
        hardDiscPath = value
    case "--record":
        guard let value = arguments.popFirst() else { usage() }
        recordPath = value
    case "--codec":
        guard let value = arguments.popFirst().flatMap(VideoRecorder.Codec.init(rawValue:)) else { usage() }
        codec = value
    case "--tape":
        guard let value = arguments.popFirst() else { usage() }
        tapePath = value
    case "--master":
        model = .master128
    case "--bplus":
        model = .bPlus
    case "--model-a":
        model = .modelA
    case "--compact":
        model = .masterCompact
    case "--tube":
        secondProcessor = true
    case "--z80":
        secondProcessor = true
        coprocessor = .z80
    case "--512":
        secondProcessor = true
        coprocessor = .master512
    case "--arm":
        secondProcessor = true
        coprocessor = .arm
    case "--turbo":
        // The Master Turbo: a Master 128 with the 65C102 Co-Processor.
        model = .master128
        secondProcessor = true
        coprocessor = .masterTurbo
    case "--drive-sounds":
        // In a recording: the disc drives' noises.
        driveSounds = true
    case "--text":
        printText = true
    case "--pcs":
        printPCs = true
    case "--trace":
        guard let value = arguments.popFirst().flatMap(Int.init) else { usage() }
        traceCount = value
    default:
        usage()
    }
}

var configuration = BeebROMs.configuration(for: model, secondProcessor: secondProcessor, coprocessor: coprocessor,
                                           econetStation: econetStation)
configuration.sidewaysROMs.merge(extraROMs) { $1 }
let machine = BBCMicro(configuration: configuration)
if let tapePath {
    do {
        machine.insertTape(try Tape(image: [UInt8](Data(contentsOf: URL(fileURLWithPath: tapePath)))))
    } catch {
        FileHandle.standardError.write(Data("beeb: couldn't read tape \(tapePath): \(error)\n".utf8))
        exit(1)
    }
}
if let discPath {
    do {
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: discPath)))
        let disc = try Disc.fromImage(bytes, named: discPath)
        machine.insertDisc(disc)
    } catch {
        FileHandle.standardError.write(Data("beeb: couldn't read disc \(discPath): \(error)\n".utf8))
        exit(1)
    }
}
if let hardDiscPath {
    let url = URL(fileURLWithPath: hardDiscPath)
    guard let image = try? Data(contentsOf: url) else {
        FileHandle.standardError.write(Data("beeb: couldn't read hard disc \(hardDiscPath)\n".utf8))
        exit(1)
    }
    let parameters = try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("dsc"))
    machine.attachHardDisc(HardDisc(image: [UInt8](image), parameters: parameters.map { [UInt8]($0) }))
}
if shiftBreak {
    machine.setKey(.shift, down: true)
}
let tv = TVOutput()
machine.tv = tv

// Recording runs from power on. Emulation is in 1/50s slices so frames and
// sound are captured as they're produced.
var recorder: MachineRecorder?
if let recordPath {
    machine.attachAudio(sampleRate: 48_000, ring: SampleRing(capacity: 48_000))
    if driveSounds {
        machine.discDriveSounds = BeebROMs.discDriveSounds(for: model)
    }
    do {
        recorder = try MachineRecorder(machine: machine, tv: tv, url: URL(fileURLWithPath: recordPath), codec: codec)
    } catch {
        FileHandle.standardError.write(Data("beeb: can't record to \(recordPath): \(error)\n".utf8))
        exit(1)
    }
}
@MainActor func run(seconds: Double) {
    guard let recorder else {
        machine.run(seconds: seconds)
        return
    }
    var remaining = seconds
    while remaining > 0 {
        let slice = min(remaining, 0.02)
        machine.run(seconds: slice)
        remaining -= slice
        try? recorder.capture()
    }
}

// Let it boot (holding Shift to boot the disc), load files, then type.
if shiftBreak {
    run(seconds: 1)
    machine.setKey(.shift, down: false)
}
if recorder != nil || shiftBreak {
    run(seconds: 1)
} else {
    machine.runUntilIdle()
}
for (discPath, name) in loads {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: discPath)) else {
        FileHandle.standardError.write(Data("beeb: couldn't read \(discPath)\n".utf8))
        exit(1)
    }
    if case .failure(let error) = machine.loadProgram(disc: [UInt8](data), file: name) {
        FileHandle.standardError.write(Data("beeb: couldn't load \(name) from \(discPath): \(error)\n".utf8))
        exit(1)
    }
}
if let typeText {
    machine.type(typeText)
    while machine.isTyping {
        run(seconds: 0.1)
    }
}
run(seconds: seconds)
if let recorder {
    do {
        try recorder.finish()
    } catch {
        FileHandle.standardError.write(Data("beeb: recording failed: \(error)\n".utf8))
        exit(1)
    }
}

if printPCs {
    // Where the CPU is spending its time.
    var counts: [UInt16: Int] = [:]
    for _ in 0..<200_000 {
        machine.step()
        if machine.cpu.isAboutToExecute {
            counts[machine.cpu.abus, default: 0] += 1
        }
    }
    let disassembler = M6502Disassembler(variant: .nmos)
    for (pc, count) in counts.sorted(by: { $0.value > $1.value }).prefix(16) {
        let text = disassembler.disassemble(at: pc, read: machine.peek).text
        print(String(format: "%04X %6d  %@", pc, count, text))
    }
}

if traceCount > 0 {
    let disassembler = M6502Disassembler(variant: .nmos)
    var printed = 0
    while printed < traceCount {
        machine.step()
        let cpu = machine.cpu
        if cpu.isAboutToExecute {
            let text = disassembler.disassemble(at: cpu.abus, read: machine.peek).text
            print(String(format: "%04X  %-16@ A=%02X X=%02X Y=%02X S=%02X P=%02X", cpu.abus, text, cpu.a, cpu.x, cpu.y, cpu.s, cpu.p))
            printed += 1
        }
    }
}

if let screenshotPath {
    do {
        try Screenshot.writePNG(tv, to: URL(fileURLWithPath: screenshotPath))
    } catch {
        FileHandle.standardError.write(Data("beeb: couldn't write \(screenshotPath): \(error)\n".utf8))
        exit(1)
    }
}

if printText {
    print(machine.screenText().joined(separator: "\n"))
}
