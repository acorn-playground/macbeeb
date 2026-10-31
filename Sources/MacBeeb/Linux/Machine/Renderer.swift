import BeebHost
import CGtk
import Foundation

/// Draws the emulator's frames with OpenGL (in a GtkGLArea): the Mac's
/// Metal renderer, shader for shader. Sharp pixels, smooth, or a CRT with
/// scanlines whose width follows brightness and an aperture grille; on a
/// colour monitor, or a green or amber monochrome one whose phosphor
/// glows on from the last frame.
@MainActor
final class Renderer {
    /// Display aspect ratio of the TV picture (b2's correction: the 16MHz
    /// pixels are slightly narrower than square at 576 lines).
    static let aspect = Double(EmulatorHost.Frame.width) * 24 / 25 / Double(EmulatorHost.Frame.height)

    let host: EmulatorHost
    var style = DisplayStyle.saved
    var monitor = Monitor.saved
    /// The frame drawn last.
    private(set) var shownFrame = -1

    private var program: GLuint = 0
    private var vertexArray: GLuint = 0
    /// The latest frame and the one before it, for the afterglow.
    private var texture: GLuint = 0
    private var previousTexture: GLuint = 0
    private var uniforms: [String: GLint] = [:]
    private(set) var failure: String?

    init(host: EmulatorHost) {
        self.host = host
    }

    /// With the GL context current (the area's realised).
    func setUp() {
        let es = macbeeb_gl_is_es() != 0
        let header = es ? "#version 300 es\nprecision highp float;\nprecision highp int;\n" : "#version 150\n"
        guard let vertex = compile(GLenum(GL_VERTEX_SHADER), header + Self.vertexSource),
              let fragment = compile(GLenum(GL_FRAGMENT_SHADER), header + Self.fragmentSource) else { return }
        program = macbeeb_gl_create_program()
        macbeeb_gl_attach_shader(program, vertex)
        macbeeb_gl_attach_shader(program, fragment)
        macbeeb_gl_link_program(program)
        macbeeb_gl_delete_shader(vertex)
        macbeeb_gl_delete_shader(fragment)
        guard macbeeb_gl_program_ok(program) != 0 else {
            var log = [CChar](repeating: 0, count: 4096)
            macbeeb_gl_program_log(program, &log, GLsizei(log.count))
            failure = String(cString: log)
            NSLog("MacBeeb: couldn't link the display shader: \(failure ?? "")")
            return
        }
        for name in ["frame", "previous", "style", "monitor", "viewportHeight"] {
            uniforms[name] = macbeeb_gl_uniform_location(program, name)
        }
        vertexArray = macbeeb_gl_gen_vertex_array()
        let blank = [UInt32](repeating: 0, count: EmulatorHost.Frame.width * EmulatorHost.Frame.height)
        for unit in [0, 1] as [GLuint] {
            let name = macbeeb_gl_gen_texture()
            macbeeb_gl_bind_texture(unit, name)
            macbeeb_gl_texture_parameters()
            blank.withUnsafeBytes { macbeeb_gl_texture_image(GLsizei(EmulatorHost.Frame.width), GLsizei(EmulatorHost.Frame.height), $0.baseAddress) }
            if unit == 0 { texture = name } else { previousTexture = name }
        }
        shownFrame = -1
    }

    /// With the GL context current (the area's being unrealised).
    func tearDown() {
        if program != 0 { macbeeb_gl_delete_program(program) }
        if texture != 0 { macbeeb_gl_delete_texture(texture) }
        if previousTexture != 0 { macbeeb_gl_delete_texture(previousTexture) }
        if vertexArray != 0 { macbeeb_gl_delete_vertex_array(vertexArray) }
        program = 0
        texture = 0
        previousTexture = 0
        vertexArray = 0
    }

    private func compile(_ type: GLenum, _ source: String) -> GLuint? {
        let shader = macbeeb_gl_create_shader(type)
        macbeeb_gl_shader_source(shader, source)
        macbeeb_gl_compile_shader(shader)
        guard macbeeb_gl_shader_ok(shader) != 0 else {
            var log = [CChar](repeating: 0, count: 4096)
            macbeeb_gl_shader_log(shader, &log, GLsizei(log.count))
            failure = String(cString: log)
            NSLog("MacBeeb: couldn't compile the display shader: \(failure ?? "")")
            macbeeb_gl_delete_shader(shader)
            return nil
        }
        return shader
    }

    /// Whether there's a frame it hasn't drawn.
    var hasNewFrame: Bool {
        guard let frame = host.frame else { return false }
        return frame.number != shownFrame
    }

    private func uploadLatestFrame() {
        guard let frame = host.frame, frame.number != shownFrame else { return }
        // A frame that follows on keeps the last one for the afterglow;
        // after a jump (a pause, a rewind) there's nothing to glow.
        let followsOn = frame.number == shownFrame + 1
        shownFrame = frame.number
        swap(&texture, &previousTexture)
        let width = GLsizei(EmulatorHost.Frame.width), height = GLsizei(EmulatorHost.Frame.height)
        frame.pixels.withUnsafeBytes { bytes in
            macbeeb_gl_bind_texture(0, texture)
            macbeeb_gl_texture_subimage(width, height, bytes.baseAddress)
            if !followsOn {
                macbeeb_gl_bind_texture(1, previousTexture)
                macbeeb_gl_texture_subimage(width, height, bytes.baseAddress)
            }
        }
    }

    /// Draws into the bound framebuffer, `width` x `height` device pixels,
    /// letterboxed to the TV's aspect ratio.
    func draw(width: Int32, height: Int32) {
        macbeeb_gl_viewport(0, 0, width, height)
        macbeeb_gl_clear(0, 0, 0)
        guard program != 0 else { return }
        uploadLatestFrame()
        var pictureWidth = Double(width), pictureHeight = Double(width) / Self.aspect
        if pictureHeight > Double(height) {
            pictureHeight = Double(height)
            pictureWidth = pictureHeight * Self.aspect
        }
        macbeeb_gl_viewport(GLint((Double(width) - pictureWidth) / 2), GLint((Double(height) - pictureHeight) / 2),
                            GLsizei(pictureWidth.rounded()), GLsizei(pictureHeight.rounded()))
        macbeeb_gl_use_program(program)
        macbeeb_gl_bind_texture(0, texture)
        macbeeb_gl_bind_texture(1, previousTexture)
        macbeeb_gl_uniform1i(uniforms["frame"] ?? -1, 0)
        macbeeb_gl_uniform1i(uniforms["previous"] ?? -1, 1)
        let styleIndex: GLint = switch style {
        case .sharp: 0
        case .smooth: 1
        case .crt: 2
        }
        let monitorIndex: GLint = switch monitor {
        case .colour: 0
        case .green: 1
        case .amber: 2
        }
        macbeeb_gl_uniform1i(uniforms["style"] ?? -1, styleIndex)
        macbeeb_gl_uniform1i(uniforms["monitor"] ?? -1, monitorIndex)
        macbeeb_gl_uniform1f(uniforms["viewportHeight"] ?? -1, GLfloat(pictureHeight))
        macbeeb_gl_bind_vertex_array(vertexArray)
        macbeeb_gl_draw_quad()
        macbeeb_gl_bind_vertex_array(0)
        macbeeb_gl_use_program(0)
    }

    /// The display as drawn at `width` x `height`, as 0x00RRGGBB pixels
    /// top row first (self-tests, and screenshots of the display as seen).
    /// With the GL context current.
    func renderPixels(width: Int, height: Int) -> [UInt32]? {
        guard program != 0 else { return nil }
        let restore = macbeeb_gl_framebuffer_binding()
        var target: GLuint = 0
        let framebuffer = macbeeb_gl_offscreen(GLsizei(width), GLsizei(height), &target)
        defer { macbeeb_gl_delete_offscreen(framebuffer, target, restore) }
        draw(width: Int32(width), height: Int32(height))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { macbeeb_gl_read_pixels(0, 0, GLsizei(width), GLsizei(height), $0.baseAddress) }
        // GL's rows go up from the bottom.
        var pixels = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = (height - 1 - y) * width * 4
            for x in 0..<width {
                let o = row + x * 4
                pixels[y * width + x] = UInt32(rgba[o]) << 16 | UInt32(rgba[o + 1]) << 8 | UInt32(rgba[o + 2])
            }
        }
        return pixels
    }

    static let vertexSource = """
    out vec2 uv;

    void main() {
        vec2 corners[4] = vec2[4](vec2(-1.0, -1.0), vec2(1.0, -1.0), vec2(-1.0, 1.0), vec2(1.0, 1.0));
        vec2 corner = corners[gl_VertexID];
        gl_Position = vec4(corner, 0.0, 1.0);
        uv = vec2((corner.x + 1.0) * 0.5, (1.0 - corner.y) * 0.5);
    }
    """

    // The Mac's Metal shader in GLSL. The textures hold the TV's
    // 0x00RRGGBB pixels as uploaded bytes (B, G, R, x), so colours are
    // read .bgr.
    static let fragmentSource = """
    in vec2 uv;
    out vec4 fragColor;

    uniform sampler2D frame;
    uniform sampler2D previous;
    uniform int style;
    uniform int monitor;
    uniform float viewportHeight;

    const float beamLines = 288.0;

    vec3 sampleLinear(sampler2D t, vec2 p) {
        return texture(t, clamp(p, 0.0, 1.0)).bgr;
    }

    vec3 sampleNearest(sampler2D t, vec2 p) {
        ivec2 size = textureSize(t, 0);
        ivec2 texel = clamp(ivec2(floor(p * vec2(size))), ivec2(0), size - 1);
        return texelFetch(t, texel, 0).bgr;
    }

    // The phosphor's colour at full brightness, in linear light.
    vec3 phosphorColour(int m) {
        return m == 1 ? vec3(0.03, 1.0, 0.06)   // P1 green, about #33FF44
                      : vec3(1.0, 0.42, 0.01);  // P3 amber, about #FFB00F
    }

    // What a monochrome monitor makes of a linear colour: the composite
    // signal's luma (weighted as gamma-encoded RGB, so blue is dim), in the
    // phosphor's colour. A colour monitor passes it through.
    vec3 phosphor(vec3 colour, int m) {
        if (m == 0) {
            return colour;
        }
        float luma = dot(pow(colour, vec3(1.0 / 2.4)), vec3(0.299, 0.587, 0.114));
        return phosphorColour(m) * pow(luma, 2.4);
    }

    // One beam line's colour at x, in linear light, slightly blurred
    // horizontally like a real spot.
    vec3 lineColour(float x, float line) {
        float y = (clamp(line, 0.0, beamLines - 1.0) + 0.5) / beamLines;
        float dx = 0.6 / float(textureSize(frame, 0).x);
        vec3 c = sampleLinear(frame, vec2(x, y)) * 0.5
               + sampleLinear(frame, vec2(x - dx, y)) * 0.25
               + sampleLinear(frame, vec2(x + dx, y)) * 0.25;
        return pow(c, vec3(2.4));
    }

    // The beam's vertical profile: brighter lines bloom wider.
    vec3 beam(vec3 colour, float distance) {
        vec3 width = mix(vec3(0.24), vec3(0.32), sqrt(colour));
        return colour * exp(-0.5 * distance * distance / (width * width));
    }

    // A monochrome phosphor still glows faintly from the last frame,
    // softly, as the glow spreads.
    vec3 afterglow(vec3 colour, vec2 p, int m) {
        if (m == 0) {
            return colour;
        }
        vec2 size = vec2(textureSize(previous, 0));
        float dx = 1.0 / size.x, dy = 1.0 / size.y;
        vec3 last = (sampleLinear(previous, p) * 2.0
                   + sampleLinear(previous, p + vec2(dx, 0.0)) + sampleLinear(previous, p - vec2(dx, 0.0))
                   + sampleLinear(previous, p + vec2(0.0, dy)) + sampleLinear(previous, p - vec2(0.0, dy))) / 6.0;
        return max(colour, phosphor(pow(last, vec3(2.4)), m) * 0.3);
    }

    void main() {
        if (style == 0 || style == 1) {
            vec3 c = style == 0 ? sampleNearest(frame, uv) : sampleLinear(frame, uv);
            if (monitor == 0) {
                fragColor = vec4(c, 1.0);
                return;
            }
            vec3 lit = afterglow(phosphor(pow(c, vec3(2.4)), monitor), uv, monitor);
            fragColor = vec4(pow(clamp(lit, 0.0, 1.0), vec3(1.0 / 2.4)), 1.0);
            return;
        }

        // CRT. Below about 2 output pixels per line, scanlines alias:
        // fade them out.
        float pixelsPerLine = viewportHeight / beamLines;
        float scanlineStrength = clamp((pixelsPerLine - 1.5) / 1.5, 0.0, 1.0);

        float y = uv.y * beamLines;
        float line = floor(y);
        float offset = y - line - 0.5;
        float neighbour = offset < 0.0 ? line - 1.0 : line + 1.0;
        vec3 here = phosphor(lineColour(uv.x, line), monitor);
        vec3 next = phosphor(lineColour(uv.x, neighbour), monitor);
        vec3 scanned = beam(here, offset) + beam(next, 1.0 - abs(offset));
        // Keep average brightness about the same as the flat picture.
        scanned *= 1.15;
        vec3 flatColour = mix(here, next, abs(offset) * 0.5);
        vec3 colour = mix(flatColour, scanned, scanlineStrength);

        colour = afterglow(colour, uv, monitor);

        // Aperture grille, when there's room for it. A monochrome tube
        // hasn't one.
        if (pixelsPerLine >= 3.0 && monitor == 0) {
            int stripe = int(gl_FragCoord.x) % 3;
            vec3 mask = vec3(stripe == 0 ? 1.0 : 0.9, stripe == 1 ? 1.0 : 0.9, stripe == 2 ? 1.0 : 0.9);
            colour *= mask * 1.06;
        }

        // A little vignetting.
        vec2 centred = uv - 0.5;
        colour *= 1.0 - dot(centred, centred) * 0.25;

        fragColor = vec4(pow(clamp(colour, 0.0, 1.0), vec3(1.0 / 2.4)), 1.0);
    }
    """
}
