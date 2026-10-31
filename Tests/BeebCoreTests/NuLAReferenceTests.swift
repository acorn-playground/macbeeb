// b2's Video ULA and VideoNuLA picture tests (b2/etc/b2_tests/5, GPLv3,
// Tom Seddon): its BASIC programs, run here as b2's test_beeb.cpp runs them,
// with the TV picture compared pixel for pixel with the pictures b2 expects.
// MacBeeb's TV is a port of b2's, so they're the same size (736x576).
//
// The programs are in Resources/nula. b2's expected pictures are read from
// reference/b2 when it's there (it isn't committed); a few are committed in
// Resources/nula/wanted so CI checks some of each kind.

#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
import Foundation
import Testing
@testable import BeebCore
import BeebROMs

enum B2Pictures {
    static let referenceFolder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("reference/b2/etc/b2_tests/5/wanted_images")

    /// The picture b2 expects: a committed copy, or (in optimised builds,
    /// or with MACBEEB_SLOW_TESTS) any of them from reference/. Nil skips
    /// the case.
    static func wanted(_ folder: String, _ name: String) -> [UInt32]? {
        let committed = testResources.appendingPathComponent("nula/wanted/\(name).png")
        if FileManager.default.fileExists(atPath: committed.path) {
            return pixels(committed)
        }
        let reference = referenceFolder.appendingPathComponent("\(folder)/\(name).png")
        guard optimisedOrSlowTestsWanted, FileManager.default.fileExists(atPath: reference.path) else { return nil }
        return pixels(reference)
    }

    /// A PNG's pixels as 0x00RRGGBB, as TVOutput has them.
    static func pixels(_ url: URL) -> [UInt32]? {
        #if !canImport(ImageIO)
        guard let data = try? Data(contentsOf: url), let image = PNGDecoding.decode(data) else { return nil }
        // Over black, as Core Graphics draws it.
        return image.pixels.map { pixel in
            let alpha = pixel >> 24
            func channel(_ shift: UInt32) -> UInt32 { ((pixel >> shift) & 0xFF) * alpha / 255 }
            return channel(16) << 16 | channel(8) << 8 | channel(0)
        }
        #else
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return (0..<width * height).map { i in
            UInt32(rgba[i * 4]) << 16 | UInt32(rgba[i * 4 + 1]) << 8 | UInt32(rgba[i * 4 + 2])
        }
        #endif
    }

    /// b2's "B tape" machine: OS 1.20 and BASIC 2, no disc system (PAGE &E00).
    static func modelBTape(nula: Bool) -> BBCMicro.Configuration {
        var c = BBCMicro.Configuration(os: BeebROMs.data(.os12), sidewaysROMs: [15: BeebROMs.data(.basic2)])
        c.videoNuLA = nula
        return c
    }

    static func master(nula: Bool) -> BBCMicro.Configuration {
        var c = BeebROMs.configuration(for: .master128)
        c.videoNuLA = nula
        return c
    }

    /// Runs a b2 test program as test_beeb.cpp does: at the prompt, load it
    /// at PAGE, set its variables, OLD and RUN, wait for the prompt again,
    /// then three more frames. Returns the last frame.
    static func run(_ configuration: BBCMicro.Configuration, program: String, before: [String]) throws -> [UInt32] {
        let m = BBCMicro(configuration: configuration)
        let tv = TVOutput()
        m.tv = tv
        m.runUntilIdle(maxSeconds: 10)
        let bytes = try testResource("nula/\(program)")
        let page = Int(m.peek(0x18)) << 8
        for (i, byte) in bytes.enumerated() { m.poke(UInt16(page + i), byte) }
        m.paste((before + ["OLD", "RUN"]).joined(separator: "\n") + "\n")
        m.runUntilIdle(maxSeconds: 10)
        let frames = tv.frameCount
        while tv.frameCount < frames + 3 { m.run(cycles: 1000) }
        return tv.lastFrame
    }

    /// Pixels that differ.
    static func differences(_ got: [UInt32], _ wanted: [UInt32]) -> Int {
        guard got.count == wanted.count else { return Int.max }
        return zip(got, wanted).filter { $0 & 0xFFFFFF != $1 & 0xFFFFFF }.count
    }
}

struct NuLAReferenceTests {
    struct ULAMode: CustomTestStringConvertible, Sendable {
        var clock: Int, flash: Int, mode: Int
        var nula: Bool
        var logical = 0, attribute = 0
        var name: String {
            "video_\(nula ? "nula" : "ula").ulamode.C\(clock).F\(flash).M\(mode)" + (nula ? ".L\(logical).A\(attribute).T0" : "")
        }
        var testDescription: String { name }
    }

    static let ulaModes: [ULAMode] = {
        var cases: [ULAMode] = []
        for c in 0...1 { for f in 0...1 { for m in 0...3 {
            cases.append(ULAMode(clock: c, flash: f, mode: m, nula: false))
            for l in 0...1 { for a in 0...1 {
                cases.append(ULAMode(clock: c, flash: f, mode: m, nula: true, logical: l, attribute: a))
            } }
        } } }
        return cases
    }()

    /// b2's ULA mode test on a Master: every pixel rate, clock and flash,
    /// on the stock ULA and with NuLA in its palette and attribute modes.
    @Test(arguments: ulaModes)
    func ulaMode(_ test: ULAMode) throws {
        guard let wanted = B2Pictures.wanted("\(test.nula ? "video_nula" : "video_ula").ulamode", test.name) else { return }
        var before = ["C%=\(test.clock)", "F%=\(test.flash)", "M%=\(test.mode)"]
        if test.nula {
            if test.logical == 1 { before.append("?&FE22=&11") }
            before.append(String(format: "?&FE22=&%02X", 0x60 | test.attribute))
        }
        let got = try B2Pictures.run(B2Pictures.master(nula: test.nula), program: "ULAMODE", before: before)
        #expect(B2Pictures.differences(got, wanted) == 0, "\(test.name)")
    }

    struct ScrollBlank: CustomTestStringConvertible, Sendable {
        var kind: String, mode: Int, value: Int
        var name: String { String(format: "video_nula.%@.M%d.%@%02d", kind, mode, kind == "scroll1" ? "O" : "N", value) }
        var testDescription: String { name }
    }

    static let scrollBlank: [ScrollBlank] = ["scroll1", "blank1"].flatMap { kind in
        (0...8).flatMap { mode in (0...15).map { ScrollBlank(kind: kind, mode: mode, value: $0) } }
    }

    /// b2's horizontal offset (function 2) and left blanking (function 3)
    /// tests on a Model B, in every screen mode and setting.
    @Test(arguments: scrollBlank)
    func scrollAndBlank(_ test: ScrollBlank) throws {
        guard let wanted = B2Pictures.wanted("video_nula.\(test.kind)", test.name) else { return }
        let variable = test.kind == "scroll1" ? "O" : "N"
        let got = try B2Pictures.run(B2Pictures.modelBTape(nula: true), program: test.kind == "scroll1" ? "SCROLL1" : "BLANK1",
                                     before: ["M%=\(test.mode)", "\(variable)%=\(test.value)"])
        #expect(B2Pictures.differences(got, wanted) == 0, "\(test.name)")
    }
}
