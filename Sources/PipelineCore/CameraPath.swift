import CoreGraphics
import Foundation
import simd

/// The result of solving the virtual camera (ARCHITECTURE §4, decision 0002).
public struct CameraPath {
    /// One corrective transform per input `FrameMotion`, in the same order. Applying
    /// `corrections[i]` to frame `i` places its content where the reference frame has it.
    public let corrections: [simd_float3x3]
    /// The rectangle, in reference-frame pixel coordinates, that is valid in every corrected
    /// frame. Not pixel-aligned: a renderer that needs integers rounds it inward.
    public let crop: CGRect
    /// `crop` area over frame area, in 0...1.
    public let cropRetention: Double

    public init(corrections: [simd_float3x3], crop: CGRect, cropRetention: Double) {
        self.corrections = corrections
        self.crop = crop
        self.cropRetention = cropRetention
    }
}

public protocol CameraPathSolver {
    /// Given per-frame motion relative to the reference, return the corrective transform for
    /// each frame plus the crop valid across all of them. Every `FrameMotion.transform` maps
    /// reference coordinates onto that frame's coordinates (see `FrameMotion`).
    func solve(motion: [FrameMotion], frameSize: CGSize) throws -> CameraPath
}

public enum CameraPathError: Error, CustomStringConvertible, Equatable {
    case noMotion
    case invalidFrameSize(CGSize)
    /// A frame's transform cannot be inverted, so it cannot be warped onto the reference.
    case singularTransform(frameIndex: Int)
    /// The warped frames share no common area, so there is nothing to crop to.
    case noCommonRegion(frameIndex: Int)

    public var description: String {
        switch self {
        case .noMotion:
            return "cannot solve a camera path from zero frames"
        case .invalidFrameSize(let size):
            return "frame size \(size.width)x\(size.height) is not positive"
        case .singularTransform(let index):
            return "frame \(index) has a transform that cannot be inverted, so it cannot be stabilized"
        case .noCommonRegion(let index):
            return "after warping frame \(index) onto the reference, the frames no longer share any common area; there is no valid crop"
        }
    }
}
