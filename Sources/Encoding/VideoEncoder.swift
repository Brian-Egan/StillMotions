import AVFoundation
import CoreVideo
import Foundation
import PipelineCore
import VideoToolbox

public enum VideoEncodingError: Error, CustomStringConvertible {
    /// Loop mode was asked of an MP4. No loop flag exists that Apple platforms honour, so
    /// writing a plain video and calling it a loop would be a lie (decision 0005).
    case loopNotSupported
    case noFrames
    case hevcUnavailable
    case frameSizeChanged(expected: String, got: String)
    case writerFailed(String)

    public var description: String {
        switch self {
        case .loopNotSupported:
            return "Loop mode is GIF-only: MP4 has no loop flag that Apple platforms honour, so a looping MP4 cannot be produced. Use Bounce or Once for video, or export a GIF (decision 0005)."
        case .noFrames: return "there are no frames to encode"
        case .hevcUnavailable: return "this machine has no HEVC encoder available"
        case .frameSizeChanged(let e, let g): return "frame size changed mid-clip: started at \(e), then got \(g)"
        case .writerFailed(let m): return "video writer failed: \(m)"
        }
    }
}

public struct VideoEncodingResult: Equatable, Sendable {
    public let frameCount: Int
    public let width: Int
    public let height: Int
}

/// HEVC video via `AVAssetWriter`, at the source frame rate, streaming: frames are pulled one at
/// a time, so memory does not depend on clip length (except Bounce's reverse pass, which reads
/// from a disk spool, not memory). No loop metadata is written, because none is honoured
/// (decision 0005).
public struct VideoEncoder {
    /// Average bits per pixel per frame. 0.08 is a clean, high-quality HEVC target for
    /// sub-1080p; the size estimator (#31) depends on this being a single known number.
    public var bitsPerPixelPerFrame: Double

    public init(bitsPerPixelPerFrame: Double = 0.08) {
        self.bitsPerPixelPerFrame = bitsPerPixelPerFrame
    }

    /// Whether this machine can encode HEVC. A hosted CI VM may have no encoder, and tests
    /// use this to skip loudly instead of failing for an environmental reason.
    public static func isHEVCEncoderAvailable() -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: 256, height: 256, codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        if let session { VTCompressionSessionInvalidate(session) }
        return status == noErr
    }

    /// Encodes the frames produced by `nextFrame` (called until it returns `nil`), in
    /// `mode`, to `url`. All frames must be the same size.
    ///
    /// - Bounce writes the clip forward, then reversed without repeating the turnaround
    ///   frame: `n` frames become `2n - 1`.
    /// - Once writes the clip as is.
    /// - Loop throws `VideoEncodingError.loopNotSupported`.
    ///
    /// `frameTimes`, when given, are the source's presentation times in seconds for the frames
    /// `nextFrame` produces, in order. The file then carries those times, so a variable-frame-rate
    /// clip plays at the speed it was shot at; without them every frame is `1 / frameRate` apart.
    /// Bounce's reverse pass replays the gaps between frames backwards. If there are fewer times
    /// than frames, the last gap repeats.
    ///
    /// Cancelling the surrounding task stops the encode and removes the partial file.
    public func encode(
        nextFrame: () throws -> CVPixelBuffer?,
        frameRate: Double,
        mode: PlaybackMode,
        frameTimes: [Double]? = nil,
        to url: URL
    ) async throws -> VideoEncodingResult {
        guard mode != .loop else { throw VideoEncodingError.loopNotSupported }
        guard Self.isHEVCEncoderAvailable() else { throw VideoEncodingError.hevcUnavailable }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }

        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var spool: FrameSpool?
        var written = 0
        var size = (width: 0, height: 0)
        // Frame timestamps are exact multiples of 1/(rate): 29.97 becomes 30000/1001 style
        // rationals via a x1000 timescale rather than drifting through Double arithmetic.
        let timescale = Int32((frameRate * 1000).rounded())
        // With real frame times: seconds on a 1/60000 grid, which holds a 600-timescale source
        // (what Live Photos use) exactly.
        let sourceTimes = frameTimes.map(FrameTiming.relative)
        /// Where each forward frame was stamped, in seconds. Bounce's reverse pass needs them.
        var stamped: [Double] = []
        func forwardTime(_ index: Int) -> Double? {
            guard let sourceTimes, !sourceTimes.isEmpty else { return nil }
            if index < sourceTimes.count { return sourceTimes[index] }
            // More frames than times: keep going at the last gap.
            let lastGap = sourceTimes.count >= 2 ? sourceTimes[sourceTimes.count - 1] - sourceTimes[sourceTimes.count - 2] : 1 / frameRate
            return sourceTimes[sourceTimes.count - 1] + Double(index - sourceTimes.count + 1) * lastGap
        }

        func fail(_ error: Error) -> Error {
            writer?.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return error
        }

        func append(_ buffer: CVPixelBuffer, at seconds: Double? = nil) async throws {
            guard let input, let adaptor else { return }
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
            let time: CMTime
            if let seconds {
                time = CMTime(value: CMTimeValue((seconds * 60_000).rounded()), timescale: 60_000)
            } else {
                time = CMTime(value: CMTimeValue(written) * 1000, timescale: timescale)
            }
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw VideoEncodingError.writerFailed(writer?.error?.localizedDescription ?? "append failed")
            }
            written += 1
        }

        do {
            while let frame = try nextFrame() {
                try Task.checkCancellation()
                let frameSize = (width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
                if writer == nil {
                    size = frameSize
                    let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
                    let settings: [String: Any] = [
                        AVVideoCodecKey: AVVideoCodecType.hevc,
                        AVVideoWidthKey: size.width,
                        AVVideoHeightKey: size.height,
                        AVVideoCompressionPropertiesKey: [
                            AVVideoAverageBitRateKey: max(300_000, Int(Double(size.width * size.height) * frameRate * bitsPerPixelPerFrame)),
                            AVVideoExpectedSourceFrameRateKey: Int(frameRate.rounded()),
                            // No B-frames: every sample is in presentation order with an
                            // explicit timestamp and the file needs no edit list, so frame
                            // counts and timing are exact.
                            AVVideoAllowFrameReorderingKey: false,
                        ] as [String: Any],
                    ]
                    let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                    i.expectsMediaDataInRealTime = false
                    let a = AVAssetWriterInputPixelBufferAdaptor(
                        assetWriterInput: i,
                        sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    )
                    guard w.canAdd(i) else { throw VideoEncodingError.writerFailed("cannot add video input") }
                    w.add(i)
                    guard w.startWriting() else { throw VideoEncodingError.writerFailed(w.error?.localizedDescription ?? "startWriting failed") }
                    w.startSession(atSourceTime: .zero)
                    (writer, input, adaptor) = (w, i, a)
                    if mode == .bounce { spool = try FrameSpool(width: size.width, height: size.height) }
                } else if frameSize != size {
                    throw VideoEncodingError.frameSizeChanged(
                        expected: "\(size.width)x\(size.height)", got: "\(frameSize.width)x\(frameSize.height)"
                    )
                }
                try spool?.append(frame)
                let seconds = forwardTime(written)
                if let seconds { stamped.append(seconds) }
                try await append(frame, at: seconds)
            }
            guard let writer, let input else { throw VideoEncodingError.noFrames }

            if let spool, spool.count >= 2 {
                // Back down the clip, skipping the last frame (just shown) so the turnaround
                // is not doubled. The first frame is included: the clip ends where it began.
                var reverseTime = stamped.last
                for index in stride(from: spool.count - 2, through: 0, by: -1) {
                    try Task.checkCancellation()
                    // Going back over the same interval the clip went forward over.
                    if let t = reverseTime, stamped.count > index + 1 { reverseTime = t + (stamped[index + 1] - stamped[index]) }
                    try await append(try spool.buffer(at: index), at: reverseTime)
                }
            }

            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw VideoEncodingError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
            }
            return VideoEncodingResult(frameCount: written, width: size.width, height: size.height)
        } catch {
            throw fail(error)
        }
    }

    /// Convenience for a frame sequence.
    public func encode<Frames: Sequence>(
        frames: Frames, frameRate: Double, mode: PlaybackMode, frameTimes: [Double]? = nil, to url: URL
    ) async throws -> VideoEncodingResult where Frames.Element == CVPixelBuffer {
        var iterator = frames.makeIterator()
        return try await encode(nextFrame: { iterator.next() }, frameRate: frameRate, mode: mode, frameTimes: frameTimes, to: url)
    }
}
