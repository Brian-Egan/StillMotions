import CoreGraphics
import Foundation
import PipelineCore
import simd

/// Pins every frame to the reference for a perfectly still, tripod-like camera
/// (decision 0002), then finds the largest crop that is valid in every warped frame (`CommonCrop`).
/// The "Locked" stabilization mode.
public struct WarpToReferenceSolver: CameraPathSolver {
    public init() {}

    public func solve(motion: [FrameMotion], frameSize: CGSize) throws -> CameraPath {
        guard !motion.isEmpty else { throw CameraPathError.noMotion }
        guard frameSize.width > 0, frameSize.height > 0 else { throw CameraPathError.invalidFrameSize(frameSize) }

        var corrections: [simd_float3x3] = []
        corrections.reserveCapacity(motion.count)
        for frame in motion {
            let determinant = frame.transform.determinant
            guard determinant.isFinite, abs(determinant) > 1e-9 else {
                throw CameraPathError.singularTransform(frameIndex: frame.index)
            }
            corrections.append(frame.transform.inverse)
        }
        let crop = try CommonCrop.largest(corrections: corrections, frameIndices: motion.map(\.index), frameSize: frameSize)
        let scale = Double(crop.width) / Double(frameSize.width)
        return CameraPath(corrections: corrections, crop: crop, cropRetention: scale * scale)
    }
}
