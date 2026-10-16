import CoreVideo
import Foundation

public enum FrameSpoolError: Error, CustomStringConvertible {
    case sizeMismatch(expected: String, got: String)
    case indexOutOfRange(Int, count: Int)
    case io(String)
    case bufferAllocationFailed

    public var description: String {
        switch self {
        case .sizeMismatch(let e, let g): return "spool holds \(e) frames but was given \(g)"
        case .indexOutOfRange(let i, let c): return "spool frame \(i) requested, but it holds \(c)"
        case .io(let m): return "spool file error: \(m)"
        case .bufferAllocationFailed: return "could not allocate a pixel buffer to read a spooled frame"
        }
    }
}

/// Frames written to a temporary file and read back by index. Bounce needs the clip again in
/// reverse, but decoding only runs forward and a full-size clip is hundreds of megabytes, so
/// each rendered frame is spooled to disk during the forward pass and read back for the
/// reverse pass. Memory stays flat however long the clip is.
///
/// BGRA only, fixed size, rows tightly packed. The file is deleted when the spool is released.
public final class FrameSpool {
    public let width: Int
    public let height: Int
    public private(set) var count = 0

    private let url: URL
    private let handle: FileHandle
    private let rowBytes: Int
    private let frameBytes: Int
    private var pool: CVPixelBufferPool?

    public init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        rowBytes = width * 4
        frameBytes = rowBytes * height
        url = FileManager.default.temporaryDirectory.appendingPathComponent("stillmotions-spool-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FrameSpoolError.io("could not create \(url.path)")
        }
        handle = try FileHandle(forUpdating: url)
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    public func append(_ buffer: CVPixelBuffer) throws {
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
            throw FrameSpoolError.sizeMismatch(
                expected: "\(width)x\(height)",
                got: "\(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))"
            )
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw FrameSpoolError.io("pixel buffer has no base address") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var packed = Data(count: frameBytes)
        packed.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                memcpy(destination.baseAddress!.advanced(by: row * rowBytes), base.advanced(by: row * stride), rowBytes)
            }
        }
        try handle.seek(toOffset: UInt64(count) * UInt64(frameBytes))
        try handle.write(contentsOf: packed)
        count += 1
    }

    /// The frame at `index`, in a pooled buffer. Pool buffers are reused once released, so a
    /// caller that keeps the buffer (an encoder that has not finished with it) is safe.
    public func buffer(at index: Int) throws -> CVPixelBuffer {
        guard index >= 0, index < count else { throw FrameSpoolError.indexOutOfRange(index, count: count) }
        try handle.seek(toOffset: UInt64(index) * UInt64(frameBytes))
        guard let data = try handle.read(upToCount: frameBytes), data.count == frameBytes else {
            throw FrameSpoolError.io("short read at frame \(index)")
        }
        if pool == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        var out: CVPixelBuffer?
        if let pool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) }
        guard let buffer = out else { throw FrameSpoolError.bufferAllocationFailed }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw FrameSpoolError.bufferAllocationFailed }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        data.withUnsafeBytes { source in
            for row in 0..<height {
                memcpy(base.advanced(by: row * stride), source.baseAddress!.advanced(by: row * rowBytes), rowBytes)
            }
        }
        return buffer
    }
}
