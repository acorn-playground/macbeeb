import Foundation
@testable import BeebCore

/// Loads a file from the test bundle's Resources folder.
func testResource(_ path: String) throws -> [UInt8] {
    let url = testResources.appendingPathComponent(path)
    return try [UInt8](Data(contentsOf: url))
}

/// A 6502 connected to 64K of flat RAM.
final class FlatMachine {
    let cpu: M6502
    var memory = [UInt8](repeating: 0, count: 0x10000)
    var cycles = 0

    init(variant: M6502.Variant) {
        cpu = M6502(variant: variant)
    }

    func load(_ bytes: [UInt8], at address: Int) {
        memory.replaceSubrange(address..<address + bytes.count, with: bytes)
    }

    /// Performs the CPU's pending bus access.
    @inline(__always)
    func access() {
        if cpu.access == .write {
            memory[Int(cpu.abus)] = cpu.dbus
        } else {
            cpu.dbus = memory[Int(cpu.abus)]
        }
    }

    /// Runs one cycle: tick, then the bus access.
    @inline(__always)
    func step() {
        cpu.tick()
        access()
        cycles += 1
    }

    /// Runs whole instructions until the next opcode fetch.
    func stepInstruction() {
        repeat { step() } while !cpu.isAboutToExecute
    }
}
