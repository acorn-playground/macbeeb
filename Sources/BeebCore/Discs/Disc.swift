// A floppy disc surface: per side and track, the flux pulses on a 2us grid.
//
// A port of jsbeeb's disc.js (Matt Godbolt et al., GPLv3), itself translated
// from beebjit by Chris Evans.
//
// Each track is a list of 32-bit words, read MSB first, one bit per 2us; a 1
// is a flux reversal. A standard track is 3125 words (200ms at 300rpm), so
// one word is one FM byte (clock and data bits interleaved) or two MFM bytes.

#if os(WASI)
import FoundationEssentials
#else
import Foundation
#endif

/// IBM floppy format constants and FM/MFM/CRC helpers.
public enum IBMDiscFormat {
    public static let bytesPerTrack = 3125
    public static let tracksPerDisc = 84
    public static let markClockPattern: UInt8 = 0xC7
    public static let idMarkDataPattern: UInt8 = 0xFE
    public static let dataMarkDataPattern: UInt8 = 0xFB
    public static let deletedDataMarkDataPattern: UInt8 = 0xF8
    public static let mfmA1Sync: UInt32 = 0x4489
    /// The index mark's sync.
    public static let mfmC2Sync: UInt32 = 0x5224
    static let stdSync00s = 6
    static let stdGap1FFs = 16
    static let stdGap2FFs = 11
    static let std10SectorGap3FFs = 21

    /// MFM starts with 3x 0xA1 sync bytes added.
    public static func crcInit(mfm: Bool) -> UInt16 { mfm ? 0xCDB4 : 0xFFFF }

    public static func crcAdd(_ crc: UInt16, _ byte: UInt8) -> UInt16 {
        var crc = crc
        var byte = byte
        for _ in 0..<8 {
            let test = (crc & 0x8000) ^ (UInt16(byte & 0x80) << 8)
            crc <<= 1
            if test != 0 { crc ^= 0x1021 }
            byte <<= 1
        }
        return crc
    }

    public static func crcAdd<S: Sequence<UInt8>>(_ crc: UInt16, _ bytes: S) -> UInt16 {
        bytes.reduce(crc, crcAdd)
    }

    public static func fmTo2usPulses(clocks: UInt8, data: UInt8) -> UInt32 {
        var pulses: UInt32 = 0
        for bit in (0..<8).reversed() {
            pulses <<= 4
            if clocks >> bit & 1 != 0 { pulses |= 0x08 }
            if data >> bit & 1 != 0 { pulses |= 0x02 }
        }
        return pulses
    }

    /// `iffy` is set for pulses off the 4us FM grid.
    static func fmFrom2usPulses(_ pulses: UInt32) -> (clocks: UInt8, data: UInt8, iffy: Bool) {
        var pulses = pulses
        var clocks: UInt8 = 0
        var data: UInt8 = 0
        var iffy = false
        for _ in 0..<8 {
            clocks = clocks << 1 | UInt8(pulses >> 31)
            data = data << 1 | UInt8(pulses >> 29 & 1)
            if pulses & 0x5000_0000 != 0 { iffy = true }
            pulses <<= 4
        }
        return (clocks, data, iffy)
    }

    /// Returns 16 pulses in the low half.
    static func mfmTo2usPulses(lastBit: Bool, data: UInt8) -> (lastBit: Bool, pulses: UInt32) {
        var pulses: UInt32 = 0
        var lastBit = lastBit
        for i in (0..<8).reversed() {
            let bit = data >> i & 1 != 0
            pulses = pulses << 2 & 0xFFFF
            if bit { pulses |= 1 } else if !lastBit { pulses |= 2 }
            lastBit = bit
        }
        return (lastBit, pulses)
    }

    /// Decodes the low 16 pulses.
    static func mfmFrom2usPulses(_ pulses: UInt32) -> UInt8 {
        var pulses = pulses
        var byte: UInt8 = 0
        for _ in 0..<8 {
            byte <<= 1
            if pulses & 0xC000 == 0x4000 { byte |= 1 }
            pulses = pulses << 2 & 0xFFFF
        }
        return byte
    }
}

struct Track: Equatable, Sendable {
    /// Room for longer-than-standard tracks.
    static let capacity = IBMDiscFormat.bytesPerTrack * 2

    var pulses: [UInt32]
    var length = IBMDiscFormat.bytesPerTrack

    init(fill byte: UInt8) {
        let word = UInt32(byte) * 0x0101_0101
        pulses = [UInt32](repeating: word, count: Self.capacity)
    }

    init(pulses: [UInt32], length: Int) {
        self.pulses = pulses
        self.length = length
    }
}

/// Encoded as the length and the pulse words, little endian, less any
/// trailing zeros: a blank track is a few bytes, a standard one 12.5KB.
extension Track: Codable {
    private enum CodingKeys: String, CodingKey { case length, pulses }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(length, forKey: .length)
        let used = (pulses.lastIndex { $0 != 0 } ?? -1) + 1
        var bytes = Data(count: used * 4)
        bytes.withUnsafeMutableBytes { raw in
            for i in 0..<used { raw.storeBytes(of: pulses[i].littleEndian, toByteOffset: i * 4, as: UInt32.self) }
        }
        try container.encode(bytes, forKey: .pulses)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        length = try container.decode(Int.self, forKey: .length)
        let bytes = try container.decode(Data.self, forKey: .pulses)
        guard (1...Self.capacity).contains(length), bytes.count % 4 == 0, bytes.count <= Self.capacity * 4 else {
            throw DecodingError.dataCorruptedError(forKey: .pulses, in: container, debugDescription: "Bad track")
        }
        var pulses = [UInt32](repeating: 0, count: Self.capacity)
        bytes.withUnsafeBytes { raw in
            for i in 0..<bytes.count / 4 {
                pulses[i] = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self))
            }
        }
        self.pulses = pulses
    }
}

/// A sector found on a track by its address marks.
struct Sector {
    var isMFM: Bool
    var idBitOffset: Int
    var dataBitOffset: Int?
    var isDeleted = false
    /// Track, side, sector, size code.
    var header: [UInt8]
    var hasHeaderCRCError: Bool
    var hasDataCRCError = false
    var data: [UInt8]?

    var trackNumber: Int { Int(header[0]) }
    var sectorNumber: Int { Int(header[2]) }
}

extension Track {
    /// Reads `count` FM or MFM bytes starting at a bit offset, wrapping at the index.
    func readBytes(at bitOffset: Int, count: Int, mfm: Bool) -> (bytes: [UInt8], iffy: Bool) {
        var position = bitOffset
        func readWord() -> UInt32 {
            let index = position >> 5
            let bit = position & 31
            var word = pulses[index] << bit
            let next = index + 1 == length ? 0 : index + 1
            if bit > 0 { word |= pulses[next] >> (32 - bit) }
            position = next << 5 | bit
            return word
        }
        var bytes = [UInt8](repeating: 0, count: count)
        var iffy = false
        var word: UInt32 = 0
        for i in 0..<count {
            if mfm {
                word = i & 1 == 0 ? readWord() : word << 16
                bytes[i] = IBMDiscFormat.mfmFrom2usPulses(word >> 16)
            } else {
                let decoded = IBMDiscFormat.fmFrom2usPulses(readWord())
                bytes[i] = decoded.data
                iffy = iffy || decoded.iffy
            }
        }
        return (bytes, iffy)
    }

    func initialCRC(mfm: Bool) -> UInt16 {
        mfm ? IBMDiscFormat.crcAdd(IBMDiscFormat.crcInit(mfm: false), [0xA1, 0xA1, 0xA1])
            : IBMDiscFormat.crcInit(mfm: false)
    }

    /// Walks the track for ID and data address marks.
    func findSectorIDs() -> [Sector] {
        // What the mark detector holds at an address mark. FM pins down the
        // high half (the tail of the zero sync run); the low half is the
        // marker byte, decoded separately.
        let fmSyncHi: UInt64 = 0x8888_8888
        let mfmMarker: UInt64 = 0xAAAA_4489_4489_4489
        var sectors: [Sector] = []
        var shiftRegister: UInt32 = 0
        var numShifts = 0
        var doMFMMarkerByte = false
        var isMFM = false
        var word: UInt32 = 0
        var detector: UInt64 = 0
        for pulseIndex in 0..<length * 32 {
            if pulseIndex & 31 == 0 { word = pulses[pulseIndex >> 5] }
            let bit = word >> 31
            detector = detector << 1 | UInt64(bit)
            shiftRegister = shiftRegister << 1 | bit
            numShifts += 1
            word <<= 1
            let dataByte: UInt8
            if detector >> 32 == fmSyncHi {
                let fm = IBMDiscFormat.fmFrom2usPulses(UInt32(truncatingIfNeeded: detector))
                if fm.iffy || fm.clocks != IBMDiscFormat.markClockPattern { continue }
                isMFM = false
                doMFMMarkerByte = false
                dataByte = fm.data
            } else if detector == mfmMarker {
                isMFM = true
                doMFMMarkerByte = true
                shiftRegister = 0
                numShifts = 0
                continue
            } else if doMFMMarkerByte && numShifts == 16 {
                dataByte = IBMDiscFormat.mfmFrom2usPulses(shiftRegister)
                doMFMMarkerByte = false
            } else {
                continue
            }
            switch dataByte {
            case IBMDiscFormat.idMarkDataPattern:
                let header = readBytes(at: pulseIndex + 1, count: 6, mfm: isMFM).bytes
                let crc = IBMDiscFormat.crcAdd(
                    IBMDiscFormat.crcAdd(initialCRC(mfm: isMFM), IBMDiscFormat.idMarkDataPattern),
                    header[0..<4])
                sectors.append(Sector(isMFM: isMFM, idBitOffset: pulseIndex + 1, header: header,
                                      hasHeaderCRCError: crc != UInt16(header[4]) << 8 | UInt16(header[5])))
                shiftRegister = 0
                numShifts = 0
            case IBMDiscFormat.dataMarkDataPattern, IBMDiscFormat.deletedDataMarkDataPattern:
                // Data without a header is ignored.
                if let last = sectors.indices.last, sectors[last].dataBitOffset == nil {
                    sectors[last].dataBitOffset = pulseIndex + 1
                    sectors[last].isDeleted = dataByte == IBMDiscFormat.deletedDataMarkDataPattern
                    shiftRegister = 0
                    numShifts = 0
                }
            default:
                break
            }
        }
        return sectors
    }

    /// Sector IDs with their data, sized by the CRC that fits.
    func findSectors() -> [Sector] {
        var sectors = findSectorIDs()
        for i in sectors.indices {
            let next = i + 1 < sectors.count ? sectors[i + 1] : nil
            readData(&sectors[i], next: next)
        }
        return sectors
    }

    private func readData(_ sector: inout Sector, next: Sector?) {
        guard let dataOffset = sector.dataBitOffset else { return }
        let pulsesPerByte = sector.isMFM ? 16 : 32
        let marker = sector.isDeleted ? IBMDiscFormat.deletedDataMarkDataPattern : IBMDiscFormat.dataMarkDataPattern
        let start = dataOffset / pulsesPerByte
        let end = (next?.idBitOffset ?? length * 32) / pulsesPerByte
        // Less the CRC and sync bytes.
        let room = end - start - 5
        var size = room < 256 ? 128 : room < 512 ? 256 : room < 1024 ? 512 : room < 2048 ? 1024 : 2048
        sector.hasDataCRCError = true
        repeat {
            let bytes = readBytes(at: dataOffset, count: size + 2, mfm: sector.isMFM).bytes
            let crc = IBMDiscFormat.crcAdd(
                IBMDiscFormat.crcAdd(initialCRC(mfm: sector.isMFM), marker), bytes[0..<size])
            if crc == UInt16(bytes[size]) << 8 | UInt16(bytes[size + 1]) {
                sector.hasDataCRCError = false
                sector.data = Array(bytes[0..<size])
                return
            }
            size >>= 1
        } while size >= 128
    }
}

/// Writes a track's pulses from the start, as a formatter would.
struct TrackBuilder {
    var track: Track
    var index = 0
    var pulsesIndex = 0
    var lastMFMBit = false
    var isMFM = false
    var crc: UInt16 = 0

    init(_ track: Track) {
        self.track = track
        self.track.length = IBMDiscFormat.bytesPerTrack
    }

    mutating func resetCRC() {
        crc = IBMDiscFormat.crcInit(mfm: false)
    }

    mutating func appendFM(_ data: UInt8, clocks: UInt8 = 0xFF) {
        guard index < Track.capacity else { return }
        track.pulses[index] = IBMDiscFormat.fmTo2usPulses(clocks: clocks, data: data)
        index += 1
        isMFM = false
        crc = IBMDiscFormat.crcAdd(crc, data)
    }

    mutating func appendFM(_ data: UInt8, count: Int) {
        for _ in 0..<count { appendFM(data) }
    }

    mutating func appendFM<S: Sequence<UInt8>>(_ bytes: S) {
        for byte in bytes { appendFM(byte) }
    }

    /// Fills to a standard track length.
    mutating func fillFM(_ data: UInt8) {
        appendFM(data, count: max(0, IBMDiscFormat.bytesPerTrack - index))
    }

    mutating func appendCRC() {
        let crc = crc
        if isMFM {
            appendMFM(UInt8(crc >> 8))
            appendMFM(UInt8(crc & 0xFF))
        } else {
            appendFM(UInt8(crc >> 8))
            appendFM(UInt8(crc & 0xFF))
        }
    }

    mutating func appendMFMPulses(_ pulses: UInt32) {
        guard index < Track.capacity else { return }
        let mask: UInt32 = 0xFFFF << pulsesIndex
        pulsesIndex = (pulsesIndex + 16) & 31
        track.pulses[index] = track.pulses[index] & mask | pulses << pulsesIndex
        if pulsesIndex == 0 { index += 1 }
        isMFM = true
    }

    mutating func appendMFM(_ data: UInt8) {
        let encoded = IBMDiscFormat.mfmTo2usPulses(lastBit: lastMFMBit, data: data)
        lastMFMBit = encoded.lastBit
        appendMFMPulses(encoded.pulses)
        crc = IBMDiscFormat.crcAdd(crc, data)
    }

    mutating func appendMFM(_ data: UInt8, count: Int) {
        for _ in 0..<count { appendMFM(data) }
    }

    mutating func appendMFM<S: Sequence<UInt8>>(_ bytes: S) {
        for byte in bytes { appendMFM(byte) }
    }

    mutating func appendMFM3xA1Sync() {
        for _ in 0..<3 {
            appendMFMPulses(IBMDiscFormat.mfmA1Sync)
            crc = IBMDiscFormat.crcAdd(crc, 0xA1)
        }
    }

    mutating func fillMFM(_ data: UInt8) {
        while index < IBMDiscFormat.bytesPerTrack { appendMFM(data) }
    }
}

/// A disc: both sides' surfaces, which the drive reads and writes pulse by
/// pulse.
public final class Disc {
    public enum Error: Swift.Error, Equatable {
        case tooLarge
        case badSize
        /// The disc holds sectors an SSD/DSD can't (e.g. copy protection).
        case notDFSImage(shortfalls: [String])
    }

    /// How an .ssd/.dsd image's tracks are laid out on the 80-track surface.
    public enum Layout: Sendable {
        /// Ask the catalogue whether it's a 40-track disc.
        case auto
        case contiguous
        /// A 40-track disc on every other track, read by double stepping.
        case expanded40
    }

    static let ssdSectorSize = 256
    static let ssdSectorsPerTrack = 10
    static let ssdTracks = 80
    static let ssdTrackSize = ssdSectorSize * ssdSectorsPerTrack
    /// Acorn's *FORM puts each track's sector 0 three slots after the last
    /// track's, leaving room to step and settle.
    static let ssdTrackSkew = 3
    static let adfsSectorsPerTrack = 16

    var tracks: [Track]
    public private(set) var tracksUsed = 0
    public private(set) var isDoubleSided = false
    /// The surface holds a 48tpi layout, read by double stepping.
    public internal(set) var is40Track = false
    /// The write-protect tab.
    public var writeProtected = false
    /// Set when the drive finishes writing a track.
    public private(set) var isModified = false
    /// Called when the drive finishes writing a track (side upper, track).
    public var onTrackWritten: ((Bool, Int) -> Void)?

    var dirty: (upper: Bool, track: Int)?

    /// A blank, unformatted disc.
    public init() {
        tracks = [Track](repeating: Track(fill: 0), count: 2 * IBMDiscFormat.tracksPerDisc)
    }

    // MARK: State

    /// Everything about the disc: both sides' surfaces and its flags.
    ///
    /// In memory a snapshot shares each track's buffer with the disc (copy
    /// on write), so it costs a few KB until the disc is next written, and
    /// then a track (25KB) per track written. Encoded, it's the pulse words
    /// of each formatted track: about 12.5KB a track, so 1MB for an 80-track
    /// single-sided disc (1.3MB in JSON's base64), which compresses well (LZFSE
    /// takes a mostly empty DFS disc to 14KB); unformatted tracks take a few
    /// bytes.
    public struct State: Codable, Sendable, Equatable {
        fileprivate var tracks: [Track]
        fileprivate var tracksUsed: Int
        fileprivate var isDoubleSided: Bool
        fileprivate var is40Track: Bool
        fileprivate var writeProtected: Bool
        fileprivate var isModified: Bool
        fileprivate var dirtyUpper: Bool?
        fileprivate var dirtyTrack: Int?

        fileprivate init(tracks: [Track], tracksUsed: Int, isDoubleSided: Bool, is40Track: Bool,
                         writeProtected: Bool, isModified: Bool, dirtyUpper: Bool?, dirtyTrack: Int?) {
            self.tracks = tracks
            self.tracksUsed = tracksUsed
            self.isDoubleSided = isDoubleSided
            self.is40Track = is40Track
            self.writeProtected = writeProtected
            self.isModified = isModified
            self.dirtyUpper = dirtyUpper
            self.dirtyTrack = dirtyTrack
        }

        private enum CodingKeys: String, CodingKey {
            case tracks, tracksUsed, isDoubleSided, is40Track, writeProtected, isModified, dirtyUpper, dirtyTrack
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tracks = try c.decode([Track].self, forKey: .tracks)
            tracksUsed = try c.decode(Int.self, forKey: .tracksUsed)
            isDoubleSided = try c.decode(Bool.self, forKey: .isDoubleSided)
            is40Track = try c.decode(Bool.self, forKey: .is40Track)
            writeProtected = try c.decode(Bool.self, forKey: .writeProtected)
            isModified = try c.decode(Bool.self, forKey: .isModified)
            dirtyUpper = try c.decodeIfPresent(Bool.self, forKey: .dirtyUpper)
            dirtyTrack = try c.decodeIfPresent(Int.self, forKey: .dirtyTrack)
            let trackRange = 0..<IBMDiscFormat.tracksPerDisc
            guard tracks.count == 2 * IBMDiscFormat.tracksPerDisc, (0...trackRange.upperBound).contains(tracksUsed),
                  dirtyTrack.map(trackRange.contains) ?? true else {
                throw DecodingError.dataCorruptedError(forKey: .tracks, in: c, debugDescription: "Bad disc state")
            }
        }
    }

    public var state: State {
        State(tracks: tracks, tracksUsed: tracksUsed, isDoubleSided: isDoubleSided, is40Track: is40Track,
              writeProtected: writeProtected, isModified: isModified, dirtyUpper: dirty?.upper, dirtyTrack: dirty?.track)
    }

    /// Leaves `onTrackWritten` as it is.
    public func restore(_ state: State) {
        precondition(state.tracks.count == 2 * IBMDiscFormat.tracksPerDisc, "Not a disc's state")
        tracks = state.tracks
        tracksUsed = state.tracksUsed
        isDoubleSided = state.isDoubleSided
        is40Track = state.is40Track
        writeProtected = state.writeProtected
        isModified = state.isModified
        if let upper = state.dirtyUpper, let track = state.dirtyTrack {
            dirty = (upper, track)
        } else {
            dirty = nil
        }
    }

    /// A disc in a saved state.
    public init(state: State) {
        tracks = []
        restore(state)
    }

    @inline(__always)
    static func trackIndex(_ upper: Bool, _ track: Int) -> Int {
        (upper ? IBMDiscFormat.tracksPerDisc : 0) + track
    }

    func trackLength(upper: Bool, track: Int) -> Int {
        tracks[Self.trackIndex(upper, track)].length
    }

    @inline(__always)
    func readPulses(upper: Bool, track: Int, position: Int) -> UInt32 {
        tracks[Self.trackIndex(upper, track)].pulses[position]
    }

    func writePulses(upper: Bool, track: Int, position: Int, _ pulses: UInt32) {
        let index = Self.trackIndex(upper, track)
        guard position < tracks[index].length else { return }
        dirty = (upper, track)
        tracks[index].pulses[position] = pulses
    }

    /// Ends the current track write; returns the track written, if any.
    @discardableResult
    func flushWrites() -> (upper: Bool, track: Int)? {
        guard let written = dirty else { return nil }
        dirty = nil
        trackWritten(written.upper, written.track)
        return written
    }

    /// Leaves a track with no flux at all, as an erase head does.
    func eraseTrack(upper: Bool, track: Int) {
        let index = Self.trackIndex(upper, track)
        tracks[index].pulses = [UInt32](repeating: 0, count: Track.capacity)
        tracks[index].length = IBMDiscFormat.bytesPerTrack
        trackWritten(upper, track)
    }

    private func trackWritten(_ upper: Bool, _ track: Int) {
        setTrackUsed(upper: upper, track: track)
        isModified = true
        onTrackWritten?(upper, track)
    }

    func setTrackUsed(upper: Bool, track: Int) {
        if upper { isDoubleSided = true }
        tracksUsed = max(tracksUsed, track + 1)
    }

    func build(upper: Bool, track: Int, _ body: (inout TrackBuilder) -> Void) {
        setTrackUsed(upper: upper, track: track)
        let index = Self.trackIndex(upper, track)
        var builder = TrackBuilder(tracks[index])
        body(&builder)
        tracks[index] = builder.track
    }

    // MARK: SSD/DSD

    public static func fromSSD(_ bytes: [UInt8], layout: Layout = .auto) throws -> Disc {
        try fromDFS(bytes, doubleSided: false, layout: layout)
    }

    /// Tracks interleaved: track 0 side 0, track 0 side 1, track 1 side 0...
    public static func fromDSD(_ bytes: [UInt8], layout: Layout = .auto) throws -> Disc {
        try fromDFS(bytes, doubleSided: true, layout: layout)
    }

    static func fromDFS(_ bytes: [UInt8], doubleSided: Bool, layout: Layout) throws -> Disc {
        let sides = doubleSided ? 2 : 1
        var data = bytes
        if data.count % ssdSectorSize != 0 {
            data += [UInt8](repeating: 0, count: ssdSectorSize - data.count % ssdSectorSize)
        }
        guard data.count <= ssdTrackSize * ssdTracks * sides else { throw Error.tooLarge }

        let disc = Disc()
        switch layout {
        case .auto: disc.is40Track = isFortyTrackDFS(bytes, doubleSided: doubleSided)
        case .contiguous: disc.is40Track = false
        case .expanded40: disc.is40Track = true
        }
        let step = disc.is40Track ? 2 : 1
        // An image can run past its nominal last track as far as the surface allows.
        let numTracks = min(IBMDiscFormat.tracksPerDisc / step,
                            max(ssdTracks / step, tracksWithData(data, sides: sides)))
        let blank = [UInt8](repeating: 0, count: ssdSectorSize)
        for track in 0..<numTracks {
            let firstSector = (ssdSectorsPerTrack - ssdTrackSkew * track % ssdSectorsPerTrack) % ssdSectorsPerTrack
            for side in 0..<sides {
                let trackOffset = (track * sides + side) * ssdTrackSize
                disc.build(upper: side == 1, track: track * step) { b in
                    // GAP 5, as the index pulse starts.
                    b.appendFM(0xFF, count: IBMDiscFormat.stdGap1FFs)
                    b.appendFM(0x00, count: IBMDiscFormat.stdSync00s)
                    for slot in 0..<ssdSectorsPerTrack {
                        let sector = (firstSector + slot) % ssdSectorsPerTrack
                        b.resetCRC()
                        b.appendFM(IBMDiscFormat.idMarkDataPattern, clocks: IBMDiscFormat.markClockPattern)
                        b.appendFM([UInt8(track), 0, UInt8(sector), 1])
                        b.appendCRC()
                        // GAP 2.
                        b.appendFM(0xFF, count: IBMDiscFormat.stdGap2FFs)
                        b.appendFM(0x00, count: IBMDiscFormat.stdSync00s)
                        let offset = trackOffset + sector * ssdSectorSize
                        b.resetCRC()
                        b.appendFM(IBMDiscFormat.dataMarkDataPattern, clocks: IBMDiscFormat.markClockPattern)
                        if offset < data.count {
                            b.appendFM(data[offset..<offset + ssdSectorSize])
                        } else {
                            b.appendFM(blank)
                        }
                        b.appendCRC()
                        if slot != ssdSectorsPerTrack - 1 {
                            // GAP 3.
                            b.appendFM(0xFF, count: IBMDiscFormat.std10SectorGap3FFs)
                            b.appendFM(0x00, count: IBMDiscFormat.stdSync00s)
                        }
                    }
                    b.fillFM(0xFF)
                }
            }
        }
        return disc
    }

    /// How many logical tracks hold anything, ignoring trailing zeros.
    static func tracksWithData(_ data: [UInt8], sides: Int) -> Int {
        guard let last = data.lastIndex(where: { $0 != 0 }) else { return 0 }
        return last / (ssdTrackSize * sides) + 1
    }

    /// Whether an SSD/DSD image was written by a 40-track drive. Only the
    /// catalogue can say: images are routinely padded or cut short.
    public static func isFortyTrackDFS(_ data: [UInt8], doubleSided: Bool) -> Bool {
        guard data.count >= 2 * ssdSectorSize else { return false }
        let entryBytes = Int(data[0x105])
        guard entryBytes % 8 == 0 && entryBytes <= 31 * 8 else { return false }
        let sectors = Int(data[0x106] & 3) << 8 | Int(data[0x107])
        guard sectors != 0 && sectors <= ssdTracks / 2 * ssdSectorsPerTrack else { return false }
        return tracksWithData(data, sides: doubleSided ? 2 : 1) <= IBMDiscFormat.tracksPerDisc / 2
    }

    /// Why a sector won't fit in an SSD/DSD image, or nil if it will.
    static func ssdShortfall(_ sector: Sector) -> String? {
        if sector.hasDataCRCError || sector.hasHeaderCRCError { return "with a CRC error" }
        guard let data = sector.data else { return "with no data" }
        if sector.sectorNumber >= ssdSectorsPerTrack { return "numbered past the \(ssdSectorsPerTrack) a track holds" }
        if data.count != ssdSectorSize { return "not \(ssdSectorSize) bytes" }
        if sector.trackNumber >= ssdTracks { return "past track \(ssdTracks)" }
        return nil
    }

    /// What the disc holds that an SSD/DSD can't, worst first.
    public func ssdShortfalls() -> [String] {
        var counts: [String: Int] = [:]
        for track in 0..<tracksUsed {
            for upper in isDoubleSided ? [false, true] : [false] {
                for sector in tracks[Self.trackIndex(upper, track)].findSectors() {
                    if let shortfall = Self.ssdShortfall(sector) { counts[shortfall, default: 0] += 1 }
                }
            }
        }
        return counts.sorted { $0.value > $1.value || $0.value == $1.value && $0.key < $1.key }
            .map { "\($0.value) sector\($0.value == 1 ? "" : "s") \($0.key)" }
    }

    /// The disc as an .ssd (or .dsd if double-sided). Sectors go where their
    /// headers say, so a 40-track layout comes back contiguous. Throws if the
    /// disc holds anything an SSD/DSD can't, unless `force`.
    public func toSSDOrDSD(force: Bool = false) throws -> [UInt8] {
        if !force {
            let shortfalls = ssdShortfalls()
            if !shortfalls.isEmpty { throw Error.notDFSImage(shortfalls: shortfalls) }
        }
        let sides = isDoubleSided ? 2 : 1
        var result = [UInt8](repeating: 0, count: sides * Self.ssdTracks * Self.ssdTrackSize)
        var numTracks = 0
        for track in 0..<tracksUsed {
            for side in 0..<sides {
                for sector in tracks[Self.trackIndex(side == 1, track)].findSectors() {
                    guard Self.ssdShortfall(sector) == nil, let data = sector.data else { continue }
                    let offset = (sector.trackNumber * sides + side) * Self.ssdTrackSize
                        + sector.sectorNumber * Self.ssdSectorSize
                    result.replaceSubrange(offset..<offset + Self.ssdSectorSize, with: data)
                    numTracks = max(numTracks, sector.trackNumber + 1)
                }
            }
        }
        return Array(result[0..<numTracks * sides * Self.ssdTrackSize])
    }

    /// Disc image file formats.
    public enum ImageFormat: String, Sendable, CaseIterable {
        /// DFS, one side.
        case ssd
        /// DFS, both sides interleaved by track.
        case dsd
        /// ADFS S or M (one side; also .ads, .adm).
        case adf
        /// ADFS L (both sides).
        case adl
        /// The Master 512's 800K DOS format: 80 tracks a side, five 1024-byte
        /// sectors (1-5), both sides interleaved by track, as BeebEm has it.
        case img
        /// 720K PC DOS: 80 tracks a side, nine 512-byte sectors (1-9), both
        /// sides interleaved by track.
        case dos

        /// The format a file name's extension says.
        public init?(path: String) {
            switch path.pathFileExtension.lowercased() {
            case "ssd": self = .ssd
            case "dsd": self = .dsd
            case "adf", "ads", "adm": self = .adf
            case "adl": self = .adl
            case "img": self = .img
            case "dos": self = .dos
            default: return nil
            }
        }

        public static let extensions = ["ssd", "dsd", "adf", "ads", "adm", "adl", "img", "dos"]

    }

    public static func fromImage(_ bytes: [UInt8], format: ImageFormat) throws -> Disc {
        switch format {
        case .ssd: try fromSSD(bytes)
        case .dsd: try fromDSD(bytes)
        case .adf: try fromADF(bytes)
        case .adl: try fromADL(bytes)
        case .img: try fromMFM(bytes, .dosPlus800K)
        case .dos: try fromMFM(bytes, .dos720K)
        }
    }

    /// The disc as an image file of `format`.
    public func toImage(_ format: ImageFormat) throws -> [UInt8] {
        switch format {
        case .ssd, .dsd: try toSSDOrDSD()
        case .adf: toADFS(doubleSided: false)
        case .adl: toADFS(doubleSided: true)
        case .img: toMFM(.dosPlus800K)
        case .dos: toMFM(.dos720K)
        }
    }

    /// Reads an image, by its file name's extension (DFS .ssd if unknown).
    public static func fromImage(_ bytes: [UInt8], named path: String) throws -> Disc {
        try fromImage(bytes, format: ImageFormat(path: path) ?? .ssd)
    }

    // MARK: ADFS (MFM; for a 1770, not readable by the 8271)

    /// ADFS S/M: one side.
    public static func fromADF(_ bytes: [UInt8]) throws -> Disc {
        try fromADFS(bytes, doubleSided: false)
    }

    /// ADFS L: both sides, interleaved by track.
    public static func fromADL(_ bytes: [UInt8]) throws -> Disc {
        try fromADFS(bytes, doubleSided: true)
    }

    /// The disc's 256-byte MFM sectors as an ADFS image (40 or 80 tracks, so
    /// other tools accept it).
    public func toADFS(doubleSided: Bool) -> [UInt8] {
        toMFM(doubleSided ? .adfsL : .adfsS)
    }

    static func fromADFS(_ data: [UInt8], doubleSided: Bool) throws -> Disc {
        try fromMFM(data, doubleSided ? .adfsL : .adfsS)
    }

    // MARK: MFM sector images (ADFS, DOS)

    /// How an image of MFM sectors lays them out: `sectorsPerTrack` sectors
    /// of `sectorSize` bytes, numbered from `firstSector`, track by track
    /// (both sides of each in turn, if `sides` is 2).
    struct MFMGeometry {
        var sectorSize: Int
        var sectorsPerTrack: Int
        var firstSector: Int
        var sides: Int
        /// The gap after each sector's data.
        var gap3: Int
        /// The side in each sector ID (ADFS leaves it 0).
        var sideInID: Bool
        /// Whether an image of 40 tracks' data is written as 40 tracks.
        var allows40Tracks: Bool

        var trackSize: Int { sectorSize * sectorsPerTrack }
        var sizeCode: UInt8 { UInt8((sectorSize / 128).trailingZeroBitCount) }

        static let adfsS = MFMGeometry(sectorSize: 256, sectorsPerTrack: 16, firstSector: 0, sides: 1, gap3: 24,
                                       sideInID: false, allows40Tracks: true)
        static var adfsL: MFMGeometry { var g = adfsS; g.sides = 2; return g }
        static let dosPlus800K = MFMGeometry(sectorSize: 1024, sectorsPerTrack: 5, firstSector: 1, sides: 2, gap3: 40,
                                             sideInID: true, allows40Tracks: false)
        static let dos720K = MFMGeometry(sectorSize: 512, sectorsPerTrack: 9, firstSector: 1, sides: 2, gap3: 84,
                                         sideInID: true, allows40Tracks: false)
    }

    static func fromMFM(_ data: [UInt8], _ g: MFMGeometry) throws -> Disc {
        guard data.count % g.sectorSize == 0 else { throw Error.badSize }
        guard data.count <= g.trackSize * ssdTracks * g.sides else { throw Error.tooLarge }
        let disc = Disc()
        let blank = [UInt8](repeating: 0, count: g.sectorSize)
        var offset = 0
        for track in 0..<ssdTracks where offset < data.count {
            for side in 0..<g.sides {
                // The 177x datasheet's recommended gaps.
                disc.build(upper: side == 1, track: track) { b in
                    b.appendMFM(0x4E, count: 60)
                    for sector in 0..<g.sectorsPerTrack {
                        b.appendMFM(0x00, count: 12)
                        b.resetCRC()
                        b.appendMFM3xA1Sync()
                        b.appendMFM(IBMDiscFormat.idMarkDataPattern)
                        b.appendMFM([UInt8(track), g.sideInID ? UInt8(side) : 0, UInt8(g.firstSector + sector), g.sizeCode])
                        b.appendCRC()
                        b.appendMFM(0x4E, count: 22)
                        b.appendMFM(0x00, count: 12)
                        b.resetCRC()
                        b.appendMFM3xA1Sync()
                        b.appendMFM(IBMDiscFormat.dataMarkDataPattern)
                        b.appendMFM(offset < data.count ? Array(data[offset..<offset + g.sectorSize]) : blank)
                        offset += g.sectorSize
                        b.appendCRC()
                        b.appendMFM(0x4E, count: g.gap3)
                    }
                    b.fillMFM(0x4E)
                }
            }
        }
        return disc
    }

    /// The disc's MFM sectors of `g`'s size as an image (80 tracks, or 40
    /// if that's all there is and `g` allows it).
    func toMFM(_ g: MFMGeometry) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: Self.ssdTracks * g.sides * g.trackSize)
        var numTracks = 0
        for track in 0..<min(tracksUsed, Self.ssdTracks) {
            for side in 0..<g.sides {
                for sector in tracks[Self.trackIndex(side == 1, track)].findSectors() {
                    let index = sector.sectorNumber - g.firstSector
                    guard sector.isMFM, !sector.hasDataCRCError, let data = sector.data, data.count == g.sectorSize,
                          index >= 0, index < g.sectorsPerTrack, sector.trackNumber < Self.ssdTracks else { continue }
                    let offset = (sector.trackNumber * g.sides + side) * g.trackSize + index * g.sectorSize
                    result.replaceSubrange(offset..<offset + g.sectorSize, with: data)
                    numTracks = max(numTracks, sector.trackNumber + 1)
                }
            }
        }
        let tracks = g.allows40Tracks && numTracks <= 40 ? 40 : Self.ssdTracks
        return Array(result[0..<tracks * g.sides * g.trackSize])
    }
}
