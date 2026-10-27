// Native/WebAssembly parity: Fixtures/scenarios.json run through the
// BeebWasm ABI natively here, and through the WebAssembly module by
// web/tests/parity.test.ts, must both give Fixtures/expected.json.
//
// MACBEEB_UPDATE_PARITY=1 rewrites expected.json from the native run (then
// the WebAssembly run has to agree with it). With MACBEEB_PARITY_STATES
// set to a folder, each save state is written there, and one the other
// host wrote at the same point is restored instead of this host's own:
// scripts/test-wasm.sh runs native, WebAssembly, then native again, so
// states cross both ways.

import Foundation
import Testing
@testable import BeebWasm

@Suite(.serialized)
struct ParityTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let roms = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/BeebROMs/ROMs")
    static let environment = ProcessInfo.processInfo.environment

    nonisolated(unsafe) static let scenarios: [[String: Any]] = {
        let data = try! Data(contentsOf: fixtures.appendingPathComponent("scenarios.json"))
        let root = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        return root["scenarios"] as! [[String: Any]]
    }()

    static func file(_ name: String) throws -> [UInt8] {
        let url = name.hasPrefix("@") ? roms.appendingPathComponent(String(name.dropFirst())) : fixtures.appendingPathComponent(name)
        return [UInt8](try Data(contentsOf: url))
    }

    static func fnv(_ bytes: some Sequence<UInt8>) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in bytes { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        return String(format: "%08x", hash)
    }

    /// The scenario's machines (one, or with "machines" several, on an
    /// Econet with "network"), made and driven only through the exported
    /// functions.
    final class Runner {
        var handle: Int32 = 0
        /// Machines after the first ("on": 1, 2...).
        var others: [Int32] = []
        var network: Int32?
        var twin: Int32?
        let scenario: [String: Any]
        var disc: String?
        /// Machines making sound, and a hash of all they've made.
        var audio: [Int32: UInt32] = [:]

        var specs: [[String: Any]] { scenario["machines"] as? [[String: Any]] ?? [scenario] }

        init(_ scenario: [String: Any]) throws {
            self.scenario = scenario
            handle = try make(specs[0])
            others = try specs.dropFirst().map(make)
            if let spec = scenario["network"] as? [String: Any] {
                let net = beeb_network_create(Int32(spec["clock"] as? Int ?? 200_000))
                #expect(net > 0)
                for machine in [handle] + others { #expect(beeb_network_add(net, machine) == 0) }
                network = net
            }
        }

        func machine(_ step: [String: Any]) -> Int32 {
            let index = step["on"] as? Int ?? 0
            return index == 0 ? handle : others[index - 1]
        }

        func make(_ spec: [String: Any]) throws -> Int32 {
            let handle = beeb_create(Int32(spec["model"] as! Int))
            #expect(handle > 0)
            for (slot, name) in spec["roms"] as! [String: String] {
                let rom = try file(name)
                #expect(rom.withUnsafeBytes { beeb_load_rom(handle, Int32(slot)!, $0.baseAddress, Int32($0.count)) } == 0)
            }
            if let station = spec["station"] as? Int { #expect(beeb_set_econet_station(handle, Int32(station)) == 0) }
            if let tube = spec["tube"] as? String {
                let rom = try file(tube)
                #expect(rom.withUnsafeBytes { beeb_set_second_processor(handle, $0.baseAddress, Int32($0.count)) } == 0)
            }
            #expect(beeb_power_on(handle) == 0)
            return handle
        }

        func run(_ cycles: Int, chunk: Int) {
            var done = 0
            while done < cycles {
                let n = Int32(min(chunk, cycles - done))
                if let network {
                    #expect(beeb_network_run(network, n) >= n)
                } else {
                    #expect(beeb_run(handle, n) == n)
                    if let twin { #expect(beeb_run(twin, n) == n) }
                }
                done += Int(n)
            }
        }

        func release() {
            if let network { _ = beeb_network_release(network) }
            for machine in [handle] + others + (twin.map { [$0] } ?? []) { _ = beeb_release(machine) }
        }

        func check(_ handle: Int32, licensed: Bool) -> [String: Any] {
            var cpu = [UInt8](repeating: 0, count: 8)
            #expect(beeb_cpu_state(handle, &cpu) == 0)
            var ram = [UInt8](repeating: 0, count: 0x8000)
            #expect(beeb_read_memory(handle, 0, 0, 0x8000, &ram) == 0x8000)
            var record: [String: Any] = [
                "cycles": Int(beeb_cycles(handle)),
                "pc": Int(cpu[0]) | Int(cpu[1]) << 8, "a": Int(cpu[2]), "x": Int(cpu[3]), "y": Int(cpu[4]),
                "s": Int(cpu[5]), "p": Int(cpu[6]),
                "ram": fnv(ram),
                "frame": String(format: "%08x", beeb_video_frame_hash(handle)),
                "frames": Int(beeb_video_frame_count(handle)),
                "status": Int(beeb_status(handle)),
            ]
            if licensed {
                let n = beeb_screen_text(handle)
                record["text"] = String(decoding: UnsafeRawBufferPointer(start: beeb_result_ptr(), count: Int(n)), as: UTF8.self)
            }
            if let disc { record["disc"] = disc }
            if audio[handle] != nil {
                // Every sample made so far, hashed as little-endian floats.
                var samples = [Float](repeating: 0, count: 4096)
                var hash = audio[handle]!
                while true {
                    let n = Int(beeb_audio_read(handle, &samples, Int32(samples.count)))
                    for sample in samples.prefix(n) {
                        for byte in withUnsafeBytes(of: sample.bitPattern.littleEndian, Array.init) { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
                    }
                    if n < samples.count { break }
                }
                audio[handle] = hash
                record["audio"] = String(format: "%08x", hash)
            }
            return record
        }

        /// Saves, then restores into a new machine (the other host's
        /// state, when there is one).
        func saveRestore(point: String) throws {
            let n = beeb_save_state(handle)
            #expect(n > 0)
            var state = [UInt8](UnsafeRawBufferPointer(start: beeb_result_ptr(), count: Int(n)))
            if let folder = environment["MACBEEB_PARITY_STATES"] {
                let base = URL(fileURLWithPath: folder).appendingPathComponent(point.replacingOccurrences(of: "/", with: "-"))
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
                try Data(state).write(to: base.appendingPathExtension("native.beebstate"))
                if let other = try? Data(contentsOf: base.appendingPathExtension("wasm.beebstate")) {
                    print("\(point): restoring the WebAssembly build's state")
                    state = [UInt8](other)
                }
            }
            #expect(beeb_release(handle) == 0)
            handle = beeb_create(Int32(scenario["model"] as! Int))
            #expect(state.withUnsafeBytes { beeb_restore_state(handle, $0.baseAddress, Int32($0.count)) } == 0)
        }
    }

    static func run(_ scenario: [String: Any]) throws -> [String: [String: Any]] {
        let name = scenario["name"] as! String
        let licensed = scenario["licensed"] as? Bool ?? false
        let runner = try Runner(scenario)
        defer { runner.release() }
        var checks: [String: [String: Any]] = [:]
        for (index, step) in (scenario["steps"] as! [[String: Any]]).enumerated() {
            if let cycles = step["run"] as? Int {
                runner.run(cycles, chunk: Int(Limits.runCycles))
            } else if let chunks = step["runChunks"] as? [Int] {
                runner.run(chunks[0], chunk: chunks[1])
            } else if let rate = step["audio"] as? Int {
                #expect(beeb_audio_start(runner.machine(step), Int32(rate)) == 0)
                runner.audio[runner.machine(step)] = 0x811C_9DC5
            } else if let stick = step["joystick"] as? [Double] {
                #expect(beeb_set_joystick(runner.machine(step), Int32(stick[0]), stick[1], stick[2], Int32(stick[3])) == 0)
            } else if step["twin"] != nil {
                runner.twin = try runner.make(runner.specs[0])
            } else if let text = step["type"] as? String {
                let bytes = Array(text.utf8)
                #expect(bytes.withUnsafeBytes { beeb_type(runner.machine(step), $0.baseAddress, Int32($0.count)) } == 0)
            } else if step["untilTyped"] != nil {
                while ([runner.handle] + runner.others).contains(where: { beeb_is_typing($0) == 1 }) {
                    runner.run(100_000, chunk: 100_000)
                }
            } else if let key = step["key"] as? [Int] {
                #expect(beeb_set_key(runner.machine(step), Int32(key[0]), Int32(key[1])) == 0)
            } else if let kind = step["reset"] as? Int {
                #expect(beeb_reset(runner.handle, Int32(kind)) == 0)
            } else if let insert = step["insertDisc"] as? [Any] {
                let image = try file(insert[2] as! String)
                #expect(image.withUnsafeBytes {
                    beeb_insert_disc(runner.handle, Int32(insert[0] as! Int), Int32(insert[1] as! Int), $0.baseAddress, Int32($0.count))
                } == 0)
            } else if let export = step["exportDisc"] as? [Int] {
                let n = beeb_export_disc(runner.handle, Int32(export[0]), Int32(export[1]))
                #expect(n > 0)
                runner.disc = fnv(UnsafeRawBufferPointer(start: beeb_result_ptr(), count: Int(max(n, 0))))
            } else if step["saveRestore"] != nil {
                try runner.saveRestore(point: "\(name)/\(index)")
            } else if let check = step["check"] as? String {
                let record = runner.check(runner.machine(step), licensed: licensed)
                checks["\(name)/\(check)"] = record
                if let twin = runner.twin {
                    #expect(NSDictionary(dictionary: runner.check(twin, licensed: licensed)) == NSDictionary(dictionary: record))
                }
            }
        }
        return checks
    }

    @Test func scenariosMatchExpected() throws {
        var all: [String: [String: Any]] = [:]
        for scenario in Self.scenarios {
            try all.merge(Self.run(scenario)) { a, _ in a }
        }
        // Scenarios that must equal another's checkpoint.
        for scenario in Self.scenarios {
            for step in scenario["steps"] as! [[String: Any]] {
                if let check = step["check"] as? String, let other = step["sameAs"] as? String {
                    let mine = "\(scenario["name"] as! String)/\(check)"
                    var a = all[mine]!, b = all[other]!
                    if let fields = step["fields"] as? [String] {
                        a = a.filter { fields.contains($0.key) }
                        b = b.filter { fields.contains($0.key) }
                    }
                    #expect(NSDictionary(dictionary: a) == NSDictionary(dictionary: b), "\(mine) vs \(other)")
                }
            }
        }
        let url = Self.fixtures.appendingPathComponent("expected.json")
        if Self.environment["MACBEEB_UPDATE_PARITY"] == "1" {
            let data = try JSONSerialization.data(withJSONObject: all, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            return
        }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: [String: Any]]
        #expect(Set(expected.keys) == Set(all.keys))
        for (key, record) in all {
            #expect(NSDictionary(dictionary: record) == NSDictionary(dictionary: expected[key] ?? [:]), "\(key)")
        }
    }

    // MARK: The ABI's checks

    @Test func rejectsBadInput() throws {
        #expect(beeb_abi_version() == 3)
        #expect(beeb_create(99) == BeebStatus.unsupported.rawValue)
        #expect(beeb_run(12345, 100) == BeebStatus.invalidHandle.rawValue)
        #expect(beeb_release(12345) == BeebStatus.invalidHandle.rawValue)
        let h = beeb_create(1)
        defer { _ = beeb_release(h) }
        #expect(beeb_run(h, 100) == BeebStatus.notReady.rawValue)
        #expect(beeb_power_on(h) == BeebStatus.notReady.rawValue)
        let short = [UInt8](repeating: 0, count: 100)
        #expect(short.withUnsafeBytes { beeb_load_rom(h, -1, $0.baseAddress, 100) } == BeebStatus.badData.rawValue)
        #expect(beeb_load_rom(h, 16, nil, 0) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_load_rom(h, 3, nil, 0x5000) == BeebStatus.badData.rawValue)
        let os = try Self.file("parity.rom")
        #expect(os.withUnsafeBytes { beeb_load_rom(h, -1, $0.baseAddress, Int32($0.count)) } == 0)
        #expect(beeb_power_on(h) == 0)
        #expect(beeb_run(h, -1) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_run(h, Limits.runCycles + 1) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_read_memory(h, 0, 0x10000, 1, nil) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_read_memory(h, 0, 0, 1, nil) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_read_memory(h, 5, 0, 0, nil) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_set_key(h, 0x80, 1) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_set_key(h, 0x0F, 1) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_insert_disc(h, 2, 0, nil, 0) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_insert_disc(h, 0, 9, nil, 0) == BeebStatus.unsupported.rawValue)
        #expect(short.withUnsafeBytes { beeb_insert_disc(h, 0, 2, $0.baseAddress, 100) } == BeebStatus.badData.rawValue)
        #expect(beeb_export_disc(h, 0, 0) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_reset(h, 7) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_set_rtc(h, 0, 13, 1, 1, 0, 0, 0) == BeebStatus.invalidArgument.rawValue)
        // A truncated or foreign state leaves the machine as it was.
        #expect(beeb_run(h, 1000) == 1000)
        let n = beeb_save_state(h)
        #expect(n > 0)
        let state = [UInt8](UnsafeRawBufferPointer(start: beeb_result_ptr(), count: Int(n)))
        #expect(state.withUnsafeBytes { beeb_restore_state(h, $0.baseAddress, n / 2) } == BeebStatus.badData.rawValue)
        #expect(short.withUnsafeBytes { beeb_restore_state(h, $0.baseAddress, 100) } == BeebStatus.badData.rawValue)
        #expect(beeb_cycles(h) == 1000)
        #expect(String(decoding: UnsafeRawBufferPointer(start: beeb_error_ptr(), count: Int(beeb_error_len())), as: UTF8.self)
                    .contains("save state"))
    }

    @Test func hardDiscsAttachAndExport() {
        let h = beeb_create(3)
        defer { _ = beeb_release(h) }
        let image = (0..<1024).map { UInt8($0 & 0xFF) }
        let dsc = [UInt8](repeating: 7, count: 22)
        #expect(image.withUnsafeBytes { i in dsc.withUnsafeBytes { d in
            beeb_attach_hard_disc(h, 0, i.baseAddress, Int32(i.count), d.baseAddress, 22) } } == 0)
        let n = beeb_export_hard_disc(h, 0, 0)
        #expect(n == 1024 && Array(UnsafeRawBufferPointer(start: beeb_result_ptr(), count: Int(n))) == image)
        #expect(beeb_export_hard_disc(h, 0, 1) == 22)
        #expect(Array(UnsafeRawBufferPointer(start: beeb_result_ptr(), count: 22)) == dsc)
        // Nothing written yet.
        #expect(beeb_hard_disc_take_written(h, 0) == 0)
        // Parameters are 22 bytes, or none (the default drive).
        #expect(image.withUnsafeBytes { beeb_attach_hard_disc(h, 1, $0.baseAddress, 16, $0.baseAddress, 5) } == BeebStatus.badData.rawValue)
        #expect(image.withUnsafeBytes { beeb_attach_hard_disc(h, 1, $0.baseAddress, 16, nil, 0) } == 0)
        #expect(beeb_export_hard_disc(h, 1, 1) == 22)
        #expect(image.withUnsafeBytes { beeb_attach_hard_disc(h, 4, $0.baseAddress, 16, nil, 0) } == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_detach_hard_disc(h, 0) == 0)
        #expect(beeb_export_hard_disc(h, 0, 0) == BeebStatus.invalidArgument.rawValue)
        #expect(beeb_set_sideways_ram(h, 1 << 4) == 0)
        #expect(beeb_set_sideways_ram(h, 0x1_0000) == BeebStatus.invalidArgument.rawValue)
    }

    @Test func networkRunsUntilHolding() {
        let n = beeb_network_create(200_000)
        defer { _ = beeb_network_release(n) }
        // With no gateway, nothing holds: it runs the lot.
        #expect(beeb_network_run_until_holding(n, 3200) == 3200)
        #expect(beeb_gateway_attach(n, 1) == 0)
        #expect(beeb_network_run_until_holding(n, 3200) == 3200)
    }

    @Test func machinesComeAndGo() {
        let before = beeb_machine_count()
        var handles: [Int32] = []
        for _ in 0..<Limits.machines - Int(before) { handles.append(beeb_create(1)) }
        #expect(handles.allSatisfy { $0 > 0 })
        #expect(beeb_create(1) == BeebStatus.limitReached.rawValue)
        for handle in handles { #expect(beeb_release(handle) == 0) }
        #expect(beeb_machine_count() == before)
        #expect(beeb_release(handles[0]) == BeebStatus.invalidHandle.rawValue)
    }
}
