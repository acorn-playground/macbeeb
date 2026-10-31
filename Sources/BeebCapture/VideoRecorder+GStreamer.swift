#if !canImport(AVFoundation)
import BeebCore
import CGStreamer
import Foundation

/// Records the emulator's picture and sound to a movie file, with
/// GStreamer (on Linux; the Mac's uses AVFoundation, through the same
/// interface).
///
/// Everything is timestamped in emulated time, so a recording plays back at
/// the BBC's real speed with sound in sync, whatever the host was doing (and
/// headless recordings can be made faster than real time). Feed it frames as
/// the TV completes them and audio samples as they're produced, from one
/// thread.
///
/// Frames and samples go to GStreamer's sources, which hold a couple of
/// seconds; the caller only waits if the encoder falls further behind.
public final class VideoRecorder: @unchecked Sendable {
    public enum Codec: String, CaseIterable, Sendable {
        case h264, hevc, proRes

        /// The usual file extension for the codec.
        public var fileExtension: String {
            self == .proRes ? "mov" : "mp4"
        }

        /// The encoders that make it, best first, and how each is set up
        /// (8Mbit/s, as the Mac's are), then its parser.
        var encoders: [(element: String, settings: String)] {
            switch self {
            case .h264:
                [("x264enc", "bitrate=8000 speed-preset=medium ! h264parse"),
                 ("openh264enc", "bitrate=8000000 ! h264parse"),
                 ("vah264enc", "bitrate=8000 ! h264parse")]
            case .hevc:
                [("x265enc", "bitrate=8000 ! h265parse"),
                 ("vah265enc", "bitrate=8000 ! h265parse")]
            case .proRes:
                // ProRes 422.
                [("avenc_prores_ks", "profile=standard")]
            }
        }

        var muxer: String {
            self == .proRes ? "qtmux" : "mp4mux"
        }
    }

    public enum RecorderError: Error, CustomStringConvertible {
        case cannotStart(String?)
        case writeFailed(String?)

        public var description: String {
            switch self {
            case .cannotStart(let reason): "can't start recording" + (reason.map { ": " + $0 } ?? "")
            case .writeFailed(let reason): "recording failed" + (reason.map { ": " + $0 } ?? "")
            }
        }
    }

    public let url: URL
    public let width: Int
    public let height: Int
    public let sampleRate: Int

    private let pipeline: UnsafeMutablePointer<GstElement>
    private let bus: UnsafeMutablePointer<GstBus>
    private let videoSource: UnsafeMutablePointer<GstAppSrc>
    private let audioSource: UnsafeMutablePointer<GstAppSrc>
    private var firstFrameCycles: UInt64?
    private var samplesQueued = 0
    private var finished = false

    private static let initialised: Bool = {
        gst_init(nil, nil)
        return true
    }()

    /// The first of `elements` this system has.
    private static func available(_ elements: [String]) -> String? {
        elements.first { name in
            guard let factory = gst_element_factory_find(name) else { return false }
            gst_object_unref(UnsafeMutableRawPointer(factory))
            return true
        }
    }

    /// `width` x `height` is the TV picture (`TVOutput.width/height`).
    public init(url: URL, codec: Codec = .h264, width: Int = TVOutput.width, height: Int = TVOutput.height,
                sampleRate: Int = 48_000) throws {
        _ = Self.initialised
        self.url = url
        self.width = width
        self.height = height
        self.sampleRate = sampleRate
        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw RecorderError.cannotStart("\(error)")
        }

        guard let video = Self.available(codec.encoders.map(\.element)),
              let settings = codec.encoders.first(where: { $0.element == video })?.settings else {
            throw RecorderError.cannotStart("there's no \(codec.rawValue) encoder (install GStreamer's \"ugly\" or \"libav\" plugins)")
        }
        guard let aac = Self.available(["avenc_aac", "voaacenc", "faac"]) else {
            throw RecorderError.cannotStart("there's no AAC encoder (install GStreamer's \"libav\" plugins)")
        }
        // Pixels are 0x00RRGGBB, little-endian: B, G, R, x in memory. The
        // 16MHz pixels are a little narrower than square (see the
        // renderer's aspect ratio). Timestamps are emulated time, and the
        // sources block when they hold 2s, which is the waiting.
        let description = """
            appsrc name=video format=time is-live=false block=true max-buffers=100 \
              caps=video/x-raw,format=BGRx,width=\(width),height=\(height),framerate=50/1,pixel-aspect-ratio=24/25 \
              ! queue ! videoconvert ! \(video) \(settings) ! queue ! mux. \
            appsrc name=audio format=time is-live=false block=true max-bytes=\(sampleRate * 4 * 2) \
              caps=audio/x-raw,format=F32LE,rate=\(sampleRate),channels=1,layout=interleaved \
              ! queue ! audioconvert ! audioresample ! \(aac) bitrate=128000 ! queue ! mux. \
            \(codec.muxer) name=mux ! filesink name=file
            """
        var error: UnsafeMutablePointer<GError>?
        guard let pipeline = gst_parse_launch(description, &error) else {
            let reason = error.map { String(cString: $0.pointee.message) }
            if let error { g_error_free(error) }
            throw RecorderError.cannotStart(reason)
        }
        if let error { g_error_free(error) }
        self.pipeline = pipeline
        guard let videoSource = macbeeb_gst_app_src(pipeline, "video"),
              let audioSource = macbeeb_gst_app_src(pipeline, "audio"),
              let sink = gst_bin_get_by_name(UnsafeMutableRawPointer(pipeline).assumingMemoryBound(to: GstBin.self), "file"),
              let bus = gst_element_get_bus(pipeline) else {
            gst_object_unref(pipeline)
            throw RecorderError.cannotStart(nil)
        }
        macbeeb_gst_set_string(sink, "location", url.path)
        gst_object_unref(sink)
        self.videoSource = videoSource
        self.audioSource = audioSource
        self.bus = bus
        if gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE {
            let reason = pendingError()
            release()
            throw RecorderError.cannotStart(reason ?? "the pipeline wouldn't start")
        }
    }

    deinit {
        if !finished {
            gst_element_set_state(pipeline, GST_STATE_NULL)
        }
        release()
    }

    private var released = false

    private func release() {
        guard !released else { return }
        released = true
        macbeeb_gst_unref_app_src(videoSource)
        macbeeb_gst_unref_app_src(audioSource)
        gst_object_unref(bus)
        gst_object_unref(pipeline)
    }

    /// An error GStreamer has posted, if it has.
    private func pendingError() -> String? {
        while let message = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR) {
            defer { gst_message_unref(message) }
            if let text = macbeeb_gst_error_text(message) {
                defer { g_free(text) }
                return String(cString: text)
            }
        }
        return nil
    }

    private func checkFailure() throws {
        if let error = pendingError() {
            throw RecorderError.writeFailed(error)
        }
    }

    /// Appends a frame completed when the machine had run `cycles` (2MHz).
    public func append(frame pixels: [UInt32], cycles: UInt64) throws {
        try checkFailure()
        let start = firstFrameCycles ?? cycles
        firstFrameCycles = start
        // 2MHz cycles to nanoseconds.
        let pts = GstClockTime(cycles - start) * 500
        let buffer = pixels.withUnsafeBytes { bytes in
            macbeeb_gst_buffer(bytes.baseAddress, gsize(width * height * 4), pts, GstClockTime(20_000_000))
        }
        guard gst_app_src_push_buffer(videoSource, buffer) == GST_FLOW_OK else {
            throw RecorderError.writeFailed(pendingError())
        }
    }

    /// Appends audio samples, which follow on from the last ones.
    public func append(audio samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        try checkFailure()
        let pts = GstClockTime(samplesQueued) * 1_000_000_000 / GstClockTime(sampleRate)
        let duration = GstClockTime(samples.count) * 1_000_000_000 / GstClockTime(sampleRate)
        samplesQueued += samples.count
        let buffer = samples.withUnsafeBytes { bytes in
            macbeeb_gst_buffer(bytes.baseAddress, gsize(bytes.count), pts, duration)
        }
        guard gst_app_src_push_buffer(audioSource, buffer) == GST_FLOW_OK else {
            throw RecorderError.writeFailed(pendingError())
        }
    }

    /// Finishes the file. Blocks until it's written.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        gst_app_src_end_of_stream(videoSource)
        gst_app_src_end_of_stream(audioSource)
        var failure: String?
        let types = GstMessageType(rawValue: GST_MESSAGE_EOS.rawValue | GST_MESSAGE_ERROR.rawValue)
        if let message = gst_bus_timed_pop_filtered(bus, GstClockTime.max, types) {
            if let text = macbeeb_gst_error_text(message) {
                failure = String(cString: text)
                g_free(text)
            }
            gst_message_unref(message)
        }
        gst_element_set_state(pipeline, GST_STATE_NULL)
        if let failure {
            throw RecorderError.writeFailed(failure)
        }
    }
}
#endif
