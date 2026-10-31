#if canImport(AVFoundation)
import AVFoundation
import BeebCore
import CoreMedia
import CoreVideo
import Foundation
import Synchronization

/// Records the emulator's picture and sound to a movie file.
///
/// Everything is timestamped in emulated time, so a recording plays back at
/// the BBC's real speed with sound in sync, whatever the host was doing (and
/// headless recordings can be made faster than real time). Feed it frames as
/// the TV completes them and audio samples as they're produced, from one
/// thread.
///
/// Media is queued and pulled by each writer input when it's ready, which
/// lets AVAssetWriter interleave the two; the caller only waits if the
/// encoder falls more than a couple of seconds behind.
public final class VideoRecorder: @unchecked Sendable {
    public enum Codec: String, CaseIterable, Sendable {
        case h264, hevc, proRes

        var videoCodec: AVVideoCodecType {
            switch self {
            case .h264: .h264
            case .hevc: .hevc
            case .proRes: .proRes422
            }
        }

        /// The usual file type for the codec.
        public var fileType: AVFileType {
            self == .proRes ? .mov : .mp4
        }
    }

    public enum RecorderError: Error, CustomStringConvertible {
        case cannotStart(Error?)
        case writeFailed(Error?)

        public var description: String {
            switch self {
            case .cannotStart(let error): "can't start recording" + Self.reason(error)
            case .writeFailed(let error): "recording failed" + Self.reason(error)
            }
        }

        /// AVFoundation's messages ("Cannot create file") say little; the
        /// underlying error usually says why.
        private static func reason(_ error: Error?) -> String {
            guard let error = error as NSError? else { return "" }
            var parts = [error.localizedDescription]
            if let reason = error.localizedFailureReason { parts.append(reason) }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                parts.append(underlying.localizedDescription)
            }
            return ": " + parts.joined(separator: " ")
        }
    }

    public let url: URL
    public let width: Int
    public let height: Int
    public let sampleRate: Int

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioFormat: CMAudioFormatDescription
    private var firstFrameCycles: UInt64?
    private var samplesQueued = 0

    private struct Queues {
        var video: [(CVPixelBuffer, CMTime)] = []
        var audio: [CMSampleBuffer] = []
        var finished = false
    }
    /// Guarded by `lock`. (CoreMedia buffers aren't Sendable, so Mutex
    /// won't hold them.)
    private var pending = Queues()
    private let lock = NSLock()

    private func withQueues<T>(_ body: (inout Queues) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&pending)
    }
    private let videoQueue = DispatchQueue(label: "macbeeb.recorder.video")
    private let audioQueue = DispatchQueue(label: "macbeeb.recorder.audio")
    private let videoDone = DispatchSemaphore(value: 0)
    private let audioDone = DispatchSemaphore(value: 0)
    private let failure = Mutex<Error?>(nil)
    /// Most frames to queue before the caller waits (2s).
    private let maxQueuedFrames = 100

    /// `width` x `height` is the TV picture (`TVOutput.width/height`).
    public init(url: URL, codec: Codec = .h264, width: Int = TVOutput.width, height: Int = TVOutput.height,
                sampleRate: Int = 48_000) throws {
        self.url = url
        self.width = width
        self.height = height
        self.sampleRate = sampleRate
        try? FileManager.default.removeItem(at: url)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writer = try AVAssetWriter(outputURL: url, fileType: codec.fileType)
        } catch {
            throw RecorderError.cannotStart(error)
        }

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.videoCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // The 16MHz pixels are a little narrower than square (see
            // Renderer.aspect).
            AVVideoPixelAspectRatioKey: [
                AVVideoPixelAspectRatioHorizontalSpacingKey: 24,
                AVVideoPixelAspectRatioVerticalSpacingKey: 25,
            ],
        ]
        if codec != .proRes {
            videoSettings[AVVideoCompressionPropertiesKey] = [AVVideoAverageBitRateKey: 8_000_000]
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])

        audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        audioInput.expectsMediaDataInRealTime = false

        var description = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                       formatDescriptionOut: &format)
        guard let format else { throw RecorderError.cannotStart(nil) }
        audioFormat = format

        writer.add(videoInput)
        writer.add(audioInput)
        guard writer.startWriting() else { throw RecorderError.cannotStart(writer.error) }
        writer.startSession(atSourceTime: .zero)

        videoInput.requestMediaDataWhenReady(on: videoQueue) { [unowned self] in
            self.drainVideo()
        }
        audioInput.requestMediaDataWhenReady(on: audioQueue) { [unowned self] in
            self.drainAudio()
        }
    }

    private func drainVideo() {
        while videoInput.isReadyForMoreMediaData {
            let (next, finished) = withQueues { q -> ((CVPixelBuffer, CMTime)?, Bool) in
                q.video.isEmpty ? (nil, q.finished) : (q.video.removeFirst(), q.finished)
            }
            guard let (buffer, time) = next else {
                if finished {
                    videoInput.markAsFinished()
                    videoDone.signal()
                }
                return
            }
            if !adaptor.append(buffer, withPresentationTime: time) {
                failure.withLock { $0 = writer.error ?? RecorderError.writeFailed(nil) }
            }
        }
    }

    private func drainAudio() {
        while audioInput.isReadyForMoreMediaData {
            let (next, finished) = withQueues { q -> (CMSampleBuffer?, Bool) in
                q.audio.isEmpty ? (nil, q.finished) : (q.audio.removeFirst(), q.finished)
            }
            guard let next else {
                if finished {
                    audioInput.markAsFinished()
                    audioDone.signal()
                }
                return
            }
            if !audioInput.append(next) {
                failure.withLock { $0 = writer.error ?? RecorderError.writeFailed(nil) }
            }
        }
    }

    /// Kicks both inputs, in case they're idle waiting for data.
    private func kick() {
        videoQueue.async { [unowned self] in self.drainVideo() }
        audioQueue.async { [unowned self] in self.drainAudio() }
    }

    private func checkFailure() throws {
        if let error = failure.withLock({ $0 }) {
            throw RecorderError.writeFailed(error)
        }
    }

    /// Appends a frame completed when the machine had run `cycles` (2MHz).
    public func append(frame pixels: [UInt32], cycles: UInt64) throws {
        let start = firstFrameCycles ?? cycles
        firstFrameCycles = start
        let time = CMTime(value: CMTimeValue(cycles - start), timescale: 2_000_000)

        guard let pool = adaptor.pixelBufferPool else { throw RecorderError.writeFailed(writer.error) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw RecorderError.writeFailed(nil) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        pixels.withUnsafeBytes { source in
            for row in 0..<height {
                (base + row * rowBytes).update(from: source.baseAddress!.assumingMemoryBound(to: UInt8.self) + row * width * 4,
                                               count: width * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        try checkFailure()
        while withQueues({ $0.video.count }) >= maxQueuedFrames {
            kick()
            Thread.sleep(forTimeInterval: 0.002)
            try checkFailure()
        }
        withQueues { $0.video.append((buffer, time)) }
        kick()
    }

    /// Appends audio samples, which follow on from the last ones.
    public func append(audio samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        try checkFailure()
        var block: CMBlockBuffer?
        let bytes = samples.count * 4
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: bytes, flags: 0, blockBufferOut: &block)
        guard let block else { throw RecorderError.writeFailed(nil) }
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: audioFormat,
            sampleCount: samples.count,
            presentationTimeStamp: CMTime(value: CMTimeValue(samplesQueued), timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sampleBuffer)
        guard let sampleBuffer else { throw RecorderError.writeFailed(nil) }
        samplesQueued += samples.count
        withQueues { $0.audio.append(sampleBuffer) }
        kick()
    }

    /// Finishes the file. Blocks until it's written.
    public func finish() throws {
        withQueues { $0.finished = true }
        kick()
        videoDone.wait()
        audioDone.wait()
        try checkFailure()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed {
            throw RecorderError.writeFailed(writer.error)
        }
    }
}
#endif
