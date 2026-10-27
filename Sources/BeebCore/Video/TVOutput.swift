// A simulated PAL monitor: turns the video stream into frames, locking onto
// the sync signals in the stream as a real TV would.
//
// A port of b2's TVOutput.cpp (Copyright (C) Tom Seddon, GPLv3).
//
// Output is `width` x `height` 32-bit pixels, 0x00RRGGBB (BGRA in memory on
// little-endian), with each scanline doubled.

#if canImport(FoundationEssentials)
import FoundationEssentials
#if canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#else
import Foundation
#endif

public final class TVOutput {
    public static let width = 736
    public static let height = 288 * 2

    enum State {
        case verticalRetrace, verticalRetraceWait, scanout, horizontalRetrace, horizontalRetraceWait, backPorch
    }

    static let unitsPerSecond = 2_000_000
    static let minUnitsBetweenVerticalRetrace = unitsPerSecond / 65
    static let maxUnitsBetweenVerticalRetrace = unitsPerSecond / 45
    static let horizontalRetraceCycles = 2 * 4
    static let backPorchCycles = 2 * 8
    static let scanOutCycles = 2 * 52
    static let verticalRetraceScanlines = 12
    static let scanlineCycles = horizontalRetraceCycles + backPorchCycles + scanOutCycles
    /// If this many lines are scanned without a vertical retrace, the TV
    /// retraces anyway.
    static let maxScannedLines = 500

    var state = State.verticalRetrace
    var x = 0
    var y = 0
    var stateTimer = 0
    var totalUnits: Int64 = 0
    var lastRetraceStart: Int64 = 0
    var lineOffset = 0

    /// The frame being scanned out. One extra row so interlaced output can
    /// overrun.
    let pixels: UnsafeMutablePointer<UInt32>
    let pixelCount = TVOutput.width * (TVOutput.height + 1)

    /// The last complete frame, copied at the start of each vertical retrace.
    public private(set) var lastFrame: [UInt32]
    /// The frame before, whose buffer the next frame reuses: once whoever
    /// was shown it has let it go, it's written in place, rather than a
    /// fresh 1.7MB copy being made (copy-on-write) every frame.
    private var spare: [UInt32] = []
    /// Incremented each time `lastFrame` is updated.
    public private(set) var frameCount = 0

    /// The frame being scanned out, as far as the beam has got: above it
    /// this field, below it the last one.
    public var currentFrame: [UInt32] {
        Array(UnsafeBufferPointer(start: pixels, count: TVOutput.width * TVOutput.height))
    }

    /// Cells of 8 pixels by one scanline: what produced each (see
    /// `update(_:metadata:)`).
    public static let metadataWidth = width / 8
    public static let metadataHeight = height / 2
    /// Set to record where each cell came from (for the debugger).
    public var recordsMetadata = false {
        didSet {
            if recordsMetadata && metadata == nil {
                metadata = .allocate(capacity: Self.metadataWidth * (Self.metadataHeight + 1))
                metadata!.initialize(repeating: 0, count: Self.metadataWidth * (Self.metadataHeight + 1))
            }
            if !recordsMetadata { lastMetadata = [] }
        }
    }
    private var metadata: UnsafeMutablePointer<UInt32>?
    /// The last complete frame's metadata, when recording it.
    public private(set) var lastMetadata: [UInt32] = []

    /// blend[i][j]: gamma-corrected 8-bit blend of 1/3 i and 2/3 j (4-bit
    /// inputs), for scaling 12MHz pixels to the 16MHz grid.
    let blend: [UInt8]

    public init(gamma: Double = 2.2) {
        pixels = .allocate(capacity: pixelCount)
        pixels.initialize(repeating: 0, count: pixelCount)
        lastFrame = [UInt32](repeating: 0, count: TVOutput.width * TVOutput.height)
        var blend = [UInt8](repeating: 0, count: 256)
        for i in 0..<16 {
            for j in 0..<16 {
                let a = pow(Double(i) / 15, gamma)
                let b = pow(Double(j) / 15, gamma)
                let value = pow((a + b + b) / 3, 1 / gamma)
                blend[i * 16 + j] = value >= 1 ? 255 : value <= 0 ? 0 : UInt8(value * 255)
            }
        }
        self.blend = blend
    }

    deinit {
        metadata?.deallocate()
        pixels.deallocate()
    }

    @inline(__always)
    private static func expand(_ p: UInt16) -> UInt32 {
        let b = UInt32(p & 0xF), g = UInt32(p >> 4 & 0xF), r = UInt32(p >> 8 & 0xF)
        return (b | b << 4) | (g | g << 4) << 8 | (r | r << 4) << 16
    }

    @inline(__always)
    private func blendPixels(_ p: UInt16, _ q: UInt16) -> UInt32 {
        let r = UInt32(blend[Int(p >> 8 & 0xF) * 16 + Int(q >> 8 & 0xF)])
        let g = UInt32(blend[Int(p >> 4 & 0xF) * 16 + Int(q >> 4 & 0xF)])
        let b = UInt32(blend[Int(p & 0xF) * 16 + Int(q & 0xF)])
        return b | g << 8 | r << 16
    }

    @inline(__always)
    private func isGoodVsync(_ unitIndex: Int64) -> Bool {
        let since = unitIndex - lastRetraceStart
        // If it's the first vsync ever, assume it's a good one.
        return (since >= Self.minUnitsBetweenVerticalRetrace && since <= Self.maxUnitsBetweenVerticalRetrace)
            || lastRetraceStart == 0
    }

    /// Consumes one unit of video.
    @inline(__always)
    public func update(_ unit: VideoUnit, metadata meta: UInt32 = 0) {
        let unitIndex = totalUnits
        totalUnits += 1

        switch state {
        case .verticalRetrace:
            let source = pixels
            var frame = spare
            spare = []
            if frame.count != TVOutput.width * TVOutput.height {
                frame = [UInt32](repeating: 0, count: TVOutput.width * TVOutput.height)
            }
            frame.withUnsafeMutableBufferPointer {
                $0.baseAddress!.update(from: source, count: $0.count)
            }
            spare = lastFrame
            lastFrame = frame
            frameCount += 1
            if recordsMetadata, let metadata {
                lastMetadata = Array(UnsafeBufferPointer(start: metadata, count: Self.metadataWidth * Self.metadataHeight))
            }
            lastRetraceStart = unitIndex
            // Odd fields start at y=0, even fields at y=2: no visible
            // interlace.
            y = x >= Self.width / 2 ? 0 : 2
            state = .verticalRetraceWait
            x = 0
            lineOffset = y * Self.width
            stateTimer = 1

        case .verticalRetraceWait:
            // Ignore everything.
            stateTimer += 1
            if stateTimer > Self.verticalRetraceScanlines * Self.scanlineCycles {
                stateTimer = 0
                state = .scanout
            }

        case .scanout:
            if unit.vsync && isGoodVsync(unitIndex) {
                state = .verticalRetrace
                break
            }
            if unit.hsync {
                state = .horizontalRetrace
                break
            }
            if x < Self.width && y < Self.height {
                scanOut(unit)
                if let metadata {
                    metadata[(y >> 1) * Self.metadataWidth + x >> 3] = meta
                }
            }
            x += 8
            stateTimer += 1
            if stateTimer > Self.scanOutCycles {
                state = .horizontalRetrace
            }

        case .horizontalRetrace:
            x = 0
            y += 2
            if y >= 2 * Self.maxScannedLines {
                // Vertical blank time anyway.
                state = .verticalRetrace
                break
            }
            lineOffset += Self.width * 2
            stateTimer = 2 // +1 for scanout, +1 for this state
            state = .horizontalRetraceWait

        case .horizontalRetraceWait:
            // Ignore input.
            stateTimer += 1
            if stateTimer >= Self.horizontalRetraceCycles {
                stateTimer = 0
                state = .backPorch
            }

        case .backPorch:
            // Ignore input.
            stateTimer += 1
            if stateTimer >= Self.backPorchCycles {
                stateTimer = 0
                state = .scanout
            }
        }
    }

    @inline(__always)
    private func scanOut(_ unit: VideoUnit) {
        let row0 = pixels + lineOffset + x
        let row1 = row0 + Self.width
        let p = unit.pixels
        switch unit.kind {
        case .bitmap16MHz:
            for i in 0..<8 {
                let value = Self.expand(p[i])
                row0[i] = value
                row1[i] = value
            }
        case .teletext:
            // 6 pixels per row at 12MHz, scaled to 8.
            let bg = p[0] & 0x0FFF, fg = p[1] & 0x0FFF
            teletextRow(row0, p[2], fg: fg, bg: bg)
            teletextRow(row1, p[3], fg: fg, bg: bg)
        case .bitmap12MHz:
            twelveMHzRow(row0, p[0], p[1], p[2], p[3], p[4], p[5])
            twelveMHzRow(row1, p[0], p[1], p[2], p[3], p[4], p[5])
        }
    }

    /// 000 011 112 222 333 344 445 555
    @inline(__always)
    private func twelveMHzRow(_ row: UnsafeMutablePointer<UInt32>,
                              _ c0: UInt16, _ c1: UInt16, _ c2: UInt16,
                              _ c3: UInt16, _ c4: UInt16, _ c5: UInt16) {
        row[0] = Self.expand(c0)
        row[1] = blendPixels(c0, c1)
        row[2] = blendPixels(c2, c1)
        row[3] = Self.expand(c2)
        row[4] = Self.expand(c3)
        row[5] = blendPixels(c3, c4)
        row[6] = blendPixels(c5, c4)
        row[7] = Self.expand(c5)
    }

    @inline(__always)
    private func teletextRow(_ row: UnsafeMutablePointer<UInt32>, _ bits: UInt16, fg: UInt16, bg: UInt16) {
        twelveMHzRow(row,
                     bits & 0x01 != 0 ? fg : bg, bits & 0x02 != 0 ? fg : bg, bits & 0x04 != 0 ? fg : bg,
                     bits & 0x08 != 0 ? fg : bg, bits & 0x10 != 0 ? fg : bg, bits & 0x20 != 0 ? fg : bg)
    }
}

