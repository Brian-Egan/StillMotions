import Accelerate
import CGifski
import CoreVideo
import Foundation
import PipelineCore

public enum GifEncodingError: Error, CustomStringConvertible {
    case noFrames
    case encoderUnavailable
    case frameSizeChanged(expected: String, got: String)
    case conversionFailed(Int)
    case gifski(String)

    public var description: String {
        switch self {
        case .noFrames: return "there are no frames to encode"
        case .encoderUnavailable: return "gifski could not be created with these settings"
        case .frameSizeChanged(let e, let g): return "frame size changed mid-clip: started at \(e), then got \(g)"
        case .conversionFailed(let code): return "converting a frame from BGRA to RGBA failed (vImage error \(code))"
        case .gifski(let m): return "gifski failed: \(m)"
        }
    }
}

public struct GifEncodingResult: Equatable, Sendable {
    public let frameCount: Int
    public let width: Int
    public let height: Int
    /// Each frame's delay, in centiseconds.
    public let delayCentiseconds: Int
    /// `nil` when the GIF plays once; otherwise 0, meaning forever.
    public let loopForever: Bool
}

/// GIF via gifski: per-frame palettes and temporal dithering, which is the whole reason it is
/// used instead of ImageIO's single-global-palette encoder (decision 0004).
///
/// Streaming. Frames are pulled one at a time and the GIF is written through gifski's write
/// callback straight to disk, so peak memory does not depend on clip length. Bounce replays the
/// clip in reverse from a disk spool, not from memory.
///
/// Looping: Loop and Bounce repeat forever (a bounce is a palindrome, so it is inherently a
/// loop); Once plays a single time.
public struct GifEncoder {
    /// gifski quality, 1 to 100. Its documentation recommends 90.
    public var quality: UInt8

    public init(quality: UInt8 = 90) {
        self.quality = quality
    }

    public func encode(
        nextFrame: () throws -> CVPixelBuffer?,
        frameRate: GifFrameRate,
        mode: PlaybackMode,
        to url: URL
    ) async throws -> GifEncodingResult {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw GifEncodingError.gifski("could not create \(url.path)")
        }
        let loopForever = mode != .once

        let sink = try GifSink(url: url)
        let sinkPointer = Unmanaged.passUnretained(sink).toOpaque()
        var handle: OpaquePointer?

        /// Created at the first frame, because gifski has to be told the output size up front.
        /// Left to itself it shrinks anything much bigger than about 800x600 pixels of area
        /// (a 1880x1056 frame comes out 940x528), which would quietly turn the Full preset into
        /// half size. Giving it the frame's own size makes it leave the pixels alone.
        func begin(width: Int, height: Int) throws {
            var settings = GifskiSettings(
                width: UInt32(width), height: UInt32(height), quality: quality, fast: false,
                repeat: loopForever ? 0 : -1
            )
            guard let created = gifski_new(&settings) else { throw GifEncodingError.encoderUnavailable }
            handle = created
            // Callbacks must be installed before any frame is added, or adding blocks forever.
            gifski_set_progress_callback(created, { userData in
                let sink = Unmanaged<GifSink>.fromOpaque(userData!).takeUnretainedValue()
                return sink.isCancelled ? 0 : 1
            }, sinkPointer)
            gifski_set_error_message_callback(created, { message, userData in
                let sink = Unmanaged<GifSink>.fromOpaque(userData!).takeUnretainedValue()
                sink.recordMessage(message.map { String(cString: $0) } ?? "unknown error")
            }, sinkPointer)
            gifski_set_write_callback(created, { length, buffer, userData in
                let sink = Unmanaged<GifSink>.fromOpaque(userData!).takeUnretainedValue()
                guard length > 0, let buffer else { return 0 }
                return sink.write(buffer, count: length) ? 0 : 1
            }, sinkPointer)
        }

        var finished = false
        func finish() -> GifskiError {
            finished = true
            guard let handle else { return GIFSKI_OK }
            return gifski_finish(handle)
        }

        var written = 0
        var size = (width: 0, height: 0)
        var spool: FrameSpool?
        let delay = Double(frameRate.centiseconds) / 100

        func add(_ buffer: CVPixelBuffer) throws {
            // Frame n is shown at exactly n * delay seconds, an exact multiple of a centisecond.
            let status = try Self.withRGBA(buffer) { pixels, bytesPerRow in
                gifski_add_frame_rgba_stride(
                    handle!, UInt32(written), UInt32(size.width), UInt32(size.height),
                    UInt32(bytesPerRow), pixels, Double(written) * delay
                )
            }
            guard status == GIFSKI_OK else {
                throw GifEncodingError.gifski(sink.firstMessage ?? "adding frame \(written) returned \(status.rawValue)")
            }
            written += 1
        }

        do {
            while let frame = try nextFrame() {
                if Task.isCancelled { throw CancellationError() }
                let frameSize = (width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
                if written == 0 {
                    size = frameSize
                    try begin(width: size.width, height: size.height)
                    if mode == .bounce { spool = try FrameSpool(width: size.width, height: size.height) }
                } else if frameSize != size {
                    throw GifEncodingError.frameSizeChanged(
                        expected: "\(size.width)x\(size.height)", got: "\(frameSize.width)x\(frameSize.height)"
                    )
                }
                try spool?.append(frame)
                try add(frame)
            }
            guard written > 0 else { throw GifEncodingError.noFrames }

            if let spool, spool.count >= 2 {
                // Back down the clip without repeating the turnaround frame (n frames -> 2n - 1).
                for index in stride(from: spool.count - 2, through: 0, by: -1) {
                    if Task.isCancelled { throw CancellationError() }
                    try add(try spool.buffer(at: index))
                }
            }

            let status = finish()
            guard status == GIFSKI_OK else {
                throw GifEncodingError.gifski(sink.firstMessage ?? "finishing returned \(status.rawValue)")
            }
            try sink.close()
            return GifEncodingResult(
                frameCount: written, width: size.width, height: size.height,
                delayCentiseconds: frameRate.centiseconds, loopForever: loopForever
            )
        } catch {
            sink.isCancelled = true
            if !finished { _ = finish() } // always: gifski leaks memory otherwise
            try? sink.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    public func encode<Frames: Sequence>(
        frames: Frames, frameRate: GifFrameRate, mode: PlaybackMode, to url: URL
    ) async throws -> GifEncodingResult where Frames.Element == CVPixelBuffer {
        var iterator = frames.makeIterator()
        return try await encode(nextFrame: { iterator.next() }, frameRate: frameRate, mode: mode, to: url)
    }

    /// Hands `body` the frame's pixels in RGBA order (gifski's order); pixel buffers are BGRA.
    static func withRGBA<T>(_ buffer: CVPixelBuffer, _ body: (UnsafePointer<UInt8>, Int) -> T) throws -> T {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw GifEncodingError.conversionFailed(-1) }

        let rowBytes = width * 4
        var rgba = [UInt8](repeating: 0, count: rowBytes * height)
        var source = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRow(buffer)
        )
        let error: vImage_Error = rgba.withUnsafeMutableBytes { raw in
            var destination = vImage_Buffer(
                data: raw.baseAddress, height: vImagePixelCount(height),
                width: vImagePixelCount(width), rowBytes: rowBytes
            )
            // B,G,R,A -> R,G,B,A
            let map: [UInt8] = [2, 1, 0, 3]
            return vImagePermuteChannels_ARGB8888(&source, &destination, map, vImage_Flags(kvImageNoFlags))
        }
        guard error == kvImageNoError else { throw GifEncodingError.conversionFailed(error) }
        return rgba.withUnsafeBufferPointer { body($0.baseAddress!, rowBytes) }
    }
}

/// Where gifski's output goes. Its write callback runs on another thread, so this takes a lock.
final class GifSink: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var messages: [String] = []
    private var failed = false
    private var cancelled = false

    init(url: URL) throws {
        handle = try FileHandle(forWritingTo: url)
    }

    var isCancelled: Bool {
        get { lock.withLock { cancelled } }
        set { lock.withLock { cancelled = newValue } }
    }

    var firstMessage: String? { lock.withLock { messages.first } }

    func recordMessage(_ message: String) {
        lock.withLock { messages.append(message) }
    }

    /// `false` on an I/O error, which gifski reports back to the caller.
    func write(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        lock.withLock {
            guard !failed else { return false }
            do {
                try handle.write(contentsOf: Data(bytes: bytes, count: count))
                return true
            } catch {
                failed = true
                messages.append("write failed: \(error)")
                return false
            }
        }
    }

    func close() throws {
        try lock.withLock { try handle.close() }
    }
}
