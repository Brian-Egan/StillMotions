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
