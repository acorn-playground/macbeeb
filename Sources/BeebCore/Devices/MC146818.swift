// MC146818 real-time clock and CMOS RAM (Master 128).
//
// A port of b2's MC146818.cpp (Copyright (C) Tom Seddon, GPLv3). Updated at
// 1MHz; the time ticks once a second. Alarms and periodic interrupts aren't
// emulated (the MOS doesn't use them).

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct MC146818: Codable, Sendable {
    public static let ramSize = 50

    enum Register {
        static let seconds = 0, minutes = 2, hours = 4
        static let dayOfWeek = 6, dayOfMonth = 7, month = 8, year = 9
        static let a = 10, b = 11, c = 12, d = 13
        static let firstRAMByte = 14
    }

    static let readOnlyMasks: [UInt8] = {
        var masks = [UInt8](repeating: 0, count: 64)
        masks[Register.a] = 0x80
        masks[Register.c] = 0xFF
        masks[Register.d] = 0xFF
        return masks
    }()

    var registers = InlineArray<64, UInt8>(repeating: 0)
    /// The selected register.
    public private(set) var address: UInt8 = 0
    var counter = 0

    /// Default Master 128 CMOS settings, as jsbeeb: MODE 7, DFS and BASIC,
    /// CAPS (location 11 bit 5; jsbeeb has SHCAPS), 6ms drive step rate
    /// (*CONFIGURE FDRIVE 0).
    public static let defaultMaster128RAM: [UInt8] = {
        var ram: [UInt8] = [
            0x00, 0xFE, 0x00, 0xEB, 0x00, 0xC9, 0xFF, 0xFF, 0x12, 0x00,
            0x17, 0xE0, 0x1E, 0x05, 0x00, 0x35, 0xA6,
        ]
        ram += [UInt8](repeating: 0, count: ramSize - ram.count)
        return ram
    }()

    public init(ram: [UInt8] = defaultMaster128RAM) {
        // 24 hour clock, BCD: the format the MOS uses.
        registers[Register.b] = 0x02
        setRAM(ram)
        // 5/12/78 is Acorn's birthday.
        setTime(year: 78, month: 12, dayOfMonth: 5, dayOfWeek: 3, hours: 12, minutes: 0, seconds: 0)
    }

    // MARK: Bus interface

    public mutating func setAddress(_ value: UInt8) {
        address = value & 63
    }

    public mutating func read() -> UInt8 {
        let index = Int(address)
        if index == Register.d {
            // Valid RAM and time.
            registers[index] |= 0x80
        }
        return registers[index]
    }

    public mutating func setData(_ value: UInt8) {
        let index = Int(address)
        let mask = Self.readOnlyMasks[index]
        registers[index] = registers[index] & mask | value & ~mask
    }

    /// Advances 1us.
    @inline(__always)
    public mutating func update() {
        if counter > 0 {
            counter -= 1
            return
        }
        counter = 1_000_000
        tick()
    }

    // MARK: CMOS RAM

    public var ram: [UInt8] {
        (0..<Self.ramSize).map { registers[Register.firstRAMByte + $0] }
    }

    public mutating func setRAM(_ data: [UInt8]) {
        for i in 0..<Self.ramSize {
            registers[Register.firstRAMByte + i] = i < data.count ? data[i] : 0
        }
    }

    // MARK: Time

    private var binary: Bool { registers[Register.b] & 0x04 != 0 }
    private var twentyFourHour: Bool { registers[Register.b] & 0x02 != 0 }
    private var settingTime: Bool { registers[Register.b] & 0x80 != 0 }

    public mutating func setTime(year: Int, month: Int, dayOfMonth: Int, dayOfWeek: Int,
                                 hours: Int, minutes: Int, seconds: Int) {
        setClamped(Register.year, year, 0, 99)
        setClamped(Register.month, month, 1, 12)
        setClamped(Register.dayOfMonth, dayOfMonth, 1, 31)
        setClamped(Register.dayOfWeek, dayOfWeek, 1, 7)
        setHours(hours)
        setClamped(Register.minutes, minutes, 0, 59)
        setClamped(Register.seconds, seconds, 0, 59)
    }

    public mutating func setTime(_ date: Date, calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute, .second], from: date)
        setTime(year: (c.year ?? 1978) % 100, month: c.month ?? 1, dayOfMonth: c.day ?? 1,
                dayOfWeek: c.weekday ?? 1, hours: c.hour ?? 0, minutes: c.minute ?? 0,
                seconds: c.second ?? 0)
    }

    private func value(_ register: Int) -> Int {
        let v = registers[register]
        if binary {
            return Int(v)
        }
        return Int(min(v >> 4, 9)) * 10 + Int(min(v & 0x0F, 9))
    }

    private mutating func set(_ register: Int, _ value: Int) {
        registers[register] = binary ? UInt8(truncatingIfNeeded: value)
            : UInt8(value % 10 + value / 10 % 10 * 16)
    }

    private mutating func setClamped(_ register: Int, _ value: Int, _ low: Int, _ high: Int) {
        set(register, max(low, min(high, value)))
    }

    /// Returns true if the value wrapped.
    private mutating func increment(_ register: Int, max high: Int, reset: Int) -> Bool {
        var n = value(register) + 1
        let wrapped = n > high
        if wrapped {
            n = reset
        }
        set(register, n)
        return wrapped
    }

    private func hours() -> Int {
        if twentyFourHour {
            return value(Register.hours)
        }
        let raw = registers[Register.hours]
        var h = (binary ? Int(raw & 0x7F) : Int(raw >> 4 & 7) * 10 + Int(min(raw & 0x0F, 9))) - 1
        if raw & 0x80 != 0 {
            h += 12
        }
        return h
    }

    private mutating func setHours(_ hours: Int) {
        let h = max(0, min(23, hours))
        if twentyFourHour {
            set(Register.hours, h)
        } else {
            set(Register.hours, 1 + h % 12)
            if h >= 12 {
                registers[Register.hours] |= 0x80
            }
        }
    }

    private mutating func tick() {
        guard !settingTime else { return }
        guard increment(Register.seconds, max: 59, reset: 0) else { return }
        guard increment(Register.minutes, max: 59, reset: 0) else { return }
        var h = hours() + 1
        let wrappedDay = h > 23
        if wrappedDay {
            h = 0
        }
        setHours(h)
        guard wrappedDay else { return }
        _ = increment(Register.dayOfWeek, max: 7, reset: 1)
        let year = value(Register.year)
        let month = max(0, min(11, value(Register.month) - 1))
        var days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month]
        if month == 1 && year & 3 == 0 {
            days = 29
        }
        guard increment(Register.dayOfMonth, max: days, reset: 1) else { return }
        guard increment(Register.month, max: 12, reset: 1) else { return }
        _ = increment(Register.year, max: 99, reset: 0)
    }
}

