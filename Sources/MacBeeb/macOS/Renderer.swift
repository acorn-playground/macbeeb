import BeebHost
import Metal
import MetalKit

/// Draws the emulator's frames with Metal.
@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    /// Display aspect ratio of the TV picture (b2's correction: the 16MHz
    /// pixels are slightly narrower than square at 576 lines).
    static let aspect: CGFloat = CGFloat(EmulatorHost.Frame.width) * 24 / 25 / CGFloat(EmulatorHost.Frame.height)

    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    /// The latest frame and the one before it, for a monochrome
    /// phosphor's afterglow.
    private var texture: MTLTexture
    private var previousTexture: MTLTexture
    let host: EmulatorHost
    var shownFrame = -1
    var style = DisplayStyle.saved
    var monitor = Monitor.saved

    /// Matches `Uniforms` in the shader.
    struct Uniforms {
        var style: UInt32
        var monitor: UInt32
        var viewportHeight: Float
    }

    init?(device: MTLDevice, pixelFormat: MTLPixelFormat, host: EmulatorHost) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.host = host

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "vertexMain")
            descriptor.fragmentFunction = library.makeFunction(name: "fragmentMain")
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("MacBeeb: couldn't build Metal pipeline: \(error)")
            return nil
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: EmulatorHost.Frame.width,
            height: EmulatorHost.Frame.height,
            mipmapped: false)
        textureDescriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: textureDescriptor),
              let previousTexture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        self.texture = texture
        self.previousTexture = previousTexture
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer() else { return }
        encode(into: commands, descriptor: descriptor, size: view.drawableSize)
        commands.present(drawable)
        commands.commit()
    }

    private func uploadLatestFrame() {
        guard let frame = host.frame, frame.number != shownFrame else { return }
        // A frame that follows on keeps the last one for the afterglow;
        // after a jump (a pause, a rewind) there's nothing to glow.
        let followsOn = frame.number == shownFrame + 1
        shownFrame = frame.number
        swap(&texture, &previousTexture)
        defer {
            if !followsOn {
                let blit = queue.makeCommandBuffer()
                let encoder = blit?.makeBlitCommandEncoder()
                encoder?.copy(from: texture, to: previousTexture)
                encoder?.endEncoding()
                blit?.commit()
            }
        }
        frame.pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, EmulatorHost.Frame.width, EmulatorHost.Frame.height),
                            mipmapLevel: 0,
                            withBytes: bytes.baseAddress!,
                            bytesPerRow: EmulatorHost.Frame.width * 4)
        }
    }

    private func encode(into commands: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, size: CGSize) {
        uploadLatestFrame()
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        // Letterbox to the TV's aspect ratio.
        var width = size.width, height = size.width / Self.aspect
        if height > size.height {
            height = size.height
            width = height * Self.aspect
        }
        encoder.setViewport(MTLViewport(originX: (size.width - width) / 2, originY: (size.height - height) / 2,
                                        width: width, height: height, znear: 0, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentTexture(previousTexture, index: 1)
        let styleIndex: UInt32 = switch style {
        case .sharp: 0
        case .smooth: 1
        case .crt: 2
        }
        let monitorIndex: UInt32 = switch monitor {
        case .colour: 0
        case .green: 1
        case .amber: 2
        }
        var uniforms = Uniforms(style: styleIndex, monitor: monitorIndex, viewportHeight: Float(height))
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Renders the current frame offscreen, as the window would show it at
    /// `width` x `height` pixels. (For self-tests and screenshots of the
    /// display as seen.)
    func renderImage(width: Int, height: Int) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        encode(into: commands, descriptor: pass, size: CGSize(width: width, height: height))
        commands.commit()
        commands.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        uint style;
        uint monitor;
        float viewportHeight;
    };

    vertex VertexOut vertexMain(uint id [[vertex_id]]) {
        float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        VertexOut out;
        out.position = float4(corners[id], 0, 1);
        out.uv = float2((corners[id].x + 1) * 0.5, (1 - corners[id].y) * 0.5);
        return out;
    }

    constant float beamLines = 288;

    // The phosphor's colour at full brightness, in linear light.
    float3 phosphorColour(uint monitor) {
        return monitor == 1 ? float3(0.03, 1.0, 0.06)   // P1 green, about #33FF44
                            : float3(1.0, 0.42, 0.01);  // P3 amber, about #FFB00F
    }

    // What a monochrome monitor makes of a linear colour: the composite
    // signal's luma (weighted as gamma-encoded RGB, so blue is dim), in the
    // phosphor's colour. A colour monitor passes it through.
    float3 phosphor(float3 colour, uint monitor) {
        if (monitor == 0) {
            return colour;
        }
        float luma = dot(pow(colour, 1 / 2.4), float3(0.299, 0.587, 0.114));
        return phosphorColour(monitor) * pow(luma, 2.4);
    }

    // One beam line's colour at x, in linear light, slightly blurred
    // horizontally like a real spot.
    float3 lineColour(texture2d<float> frame, float x, float line) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = (clamp(line, 0.0, beamLines - 1) + 0.5) / beamLines;
        float dx = 0.6 / frame.get_width();
        float3 c = frame.sample(s, float2(x, y)).rgb * 0.5
                 + frame.sample(s, float2(x - dx, y)).rgb * 0.25
                 + frame.sample(s, float2(x + dx, y)).rgb * 0.25;
        return pow(c, 2.4);
    }

    // The beam's vertical profile: brighter lines bloom wider.
    float3 beam(float3 colour, float distance) {
        float3 width = mix(float3(0.24), float3(0.32), sqrt(colour));
        return colour * exp(-0.5 * distance * distance / (width * width));
    }

    // A monochrome phosphor still glows faintly from the last frame,
    // softly, as the glow spreads.
    float3 afterglow(float3 colour, texture2d<float> previous, float2 uv, uint monitor) {
        if (monitor == 0) {
            return colour;
        }
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float dx = 1.0 / previous.get_width(), dy = 1.0 / previous.get_height();
        float3 last = (previous.sample(s, uv).rgb * 2
                     + previous.sample(s, uv + float2(dx, 0)).rgb + previous.sample(s, uv - float2(dx, 0)).rgb
                     + previous.sample(s, uv + float2(0, dy)).rgb + previous.sample(s, uv - float2(0, dy)).rgb) / 6;
        return max(colour, phosphor(pow(last, 2.4), monitor) * 0.3);
    }

    fragment float4 fragmentMain(VertexOut in [[stage_in]],
                                 texture2d<float> frame [[texture(0)]],
                                 texture2d<float> previous [[texture(1)]],
                                 constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler nearestSampler(filter::nearest);
        constexpr sampler linearSampler(filter::linear);
        if (u.style == 0 || u.style == 1) {
            float3 c = u.style == 0 ? frame.sample(nearestSampler, in.uv).rgb : frame.sample(linearSampler, in.uv).rgb;
            if (u.monitor == 0) {
                return float4(c, 1);
            }
            float3 lit = afterglow(phosphor(pow(c, 2.4), u.monitor), previous, in.uv, u.monitor);
            return float4(pow(saturate(lit), 1 / 2.4), 1);
        }

        // CRT. Below about 2 output pixels per line, scanlines alias:
        // fade them out.
        float pixelsPerLine = u.viewportHeight / beamLines;
        float scanlineStrength = saturate((pixelsPerLine - 1.5) / 1.5);

        float y = in.uv.y * beamLines;
        float line = floor(y);
        float offset = y - line - 0.5;
        float neighbour = offset < 0 ? line - 1 : line + 1;
        float3 here = phosphor(lineColour(frame, in.uv.x, line), u.monitor);
        float3 next = phosphor(lineColour(frame, in.uv.x, neighbour), u.monitor);
        float3 scanned = beam(here, offset) + beam(next, 1 - abs(offset));
        // Keep average brightness about the same as the flat picture.
        scanned *= 1.15;
        float3 flat = mix(here, next, abs(offset) * 0.5);
        float3 colour = mix(flat, scanned, scanlineStrength);

        colour = afterglow(colour, previous, in.uv, u.monitor);

        // Aperture grille, when there's room for it. A monochrome tube
        // hasn't one.
        if (pixelsPerLine >= 3 && u.monitor == 0) {
            uint stripe = uint(in.position.x) % 3;
            float3 mask = float3(stripe == 0 ? 1.0 : 0.9, stripe == 1 ? 1.0 : 0.9, stripe == 2 ? 1.0 : 0.9);
            colour *= mask * 1.06;
        }

        // A little vignetting.
        float2 centred = in.uv - 0.5;
        colour *= 1 - dot(centred, centred) * 0.25;

        return float4(pow(saturate(colour), 1 / 2.4), 1);
    }
    """
}
