import Foundation

/// A tiny grayscale picture of one stabilized, cropped frame, used to compare frames cheaply.
/// Loop selection only needs to know how different two frames look, so it works on these
/// (64x36 is 2,304 numbers) rather than on full frames, and never holds a decoded clip.
public struct FrameSignature: Equatable {
    /// Row-major luma, 0...1.
    public let luma: [Float]

    public init(luma: [Float]) {
        self.luma = luma
    }

    /// Mean absolute difference to `other`, 0 (identical) to 1 (black against white).
    public func difference(to other: FrameSignature) -> Double {
        precondition(luma.count == other.luma.count, "signatures must have the same size")
        guard !luma.isEmpty else { return 0 }
        var sum: Float = 0
        for i in 0..<luma.count { sum += abs(luma[i] - other.luma[i]) }
        return Double(sum) / Double(luma.count)
    }

    /// `weight` of `other` mixed into `self`. Linear, so a blend of signatures is the
    /// signature of the blended frames.
    public func blended(with other: FrameSignature, weight: Float) -> FrameSignature {
        precondition(luma.count == other.luma.count, "signatures must have the same size")
        var mixed = luma
        for i in 0..<mixed.count { mixed[i] = luma[i] * (1 - weight) + other.luma[i] * weight }
        return FrameSignature(luma: mixed)
    }
}

import CoreVideo

extension FrameSignature {
    /// The luma of a BGRA pixel buffer (Rec. 601 weights), 0...1.
    public init?(pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var luma = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = bytes + y * stride
            for x in 0..<width {
                let p = row + x * 4 // B, G, R, A
                luma[y * width + x] = (0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])) / 255
            }
        }
        self.init(luma: luma)
    }
}
