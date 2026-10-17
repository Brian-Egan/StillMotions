import CoreGraphics
import Foundation
import PipelineCore
import simd

/// The "Off" stabilization mode: the clip as shot. Every correction is the identity and the crop is
/// the whole frame, so nothing is warped and nothing is lost.
public struct OriginalPathSolver: CameraPathSolver {
    public init() {}

    public func solve(motion: [FrameMotion], frameSize: CGSize) throws -> CameraPath {
        guard !motion.isEmpty else { throw CameraPathError.noMotion }
        guard frameSize.width > 0, frameSize.height > 0 else { throw CameraPathError.invalidFrameSize(frameSize) }
        return CameraPath(
            corrections: Array(repeating: matrix_identity_float3x3, count: motion.count),
            crop: CGRect(origin: .zero, size: frameSize),
            cropRetention: 1
        )
    }
}
