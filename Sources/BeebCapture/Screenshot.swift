import BeebCore
import Foundation
#if canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

public enum Screenshot {
    #if canImport(ImageIO)
    /// The TV's last complete frame as an image, at native resolution
    /// (736x576, each scanline doubled).
    public static func image(_ tv: TVOutput) -> CGImage? {
        image(pixels: tv.lastFrame, width: TVOutput.width, height: TVOutput.height)
    }

    /// An image from 0x00RRGGBB pixels.
    public static func image(pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    #endif

    /// PNG data for the TV's last complete frame.
    public static func png(_ tv: TVOutput) -> Data? {
        png(pixels: tv.lastFrame, width: TVOutput.width, height: TVOutput.height)
    }

    /// PNG data from 0x00RRGGBB pixels.
    public static func png(pixels: [UInt32], width: Int, height: Int) -> Data? {
        #if canImport(ImageIO)
        guard let image = image(pixels: pixels, width: width, height: height) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
        #else
        return PNGEncoder.encode(pixels: pixels, width: width, height: height)
        #endif
    }

    public static func writePNG(_ tv: TVOutput, to url: URL) throws {
        guard let data = png(tv) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}
