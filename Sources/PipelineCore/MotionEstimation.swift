import CoreGraphics
import CoreVideo
import simd

/// A matched point pair, when an estimator produces one. See `FrameMotion.correspondences`.
public struct Correspondence: Equatable {
    public let from: CGPoint
    public let to: CGPoint

    public init(from: CGPoint, to: CGPoint) {
        self.from = from
        self.to = to
    }
}

/// One frame's motion relative to the reference frame (ARCHITECTURE §4).
///
/// Convention (matches `FixtureTruth`, decision 0002's "invert to produce corrections"):
/// `transform` maps the REFERENCE frame's coordinates onto THIS frame's coordinates, i.e.
/// `pFrame = transform * pReference`. Stabilizing this frame back onto the reference means
/// applying `transform.inverse` — that inversion is `WarpToReferenceSolver`'s job (#12),
/// not the estimator's.
public struct FrameMotion {
    public let index: Int
    public let transform: simd_float3x3
    /// Empty when the estimator does not produce correspondences (e.g. registration).
    public let correspondences: [Correspondence]
    /// Fraction of correspondences agreeing with `transform`. `nil` when not measurable —
    /// deliberately not `1.0`, which would claim confidence that does not exist
    /// (decisions/0001-motion-estimation.md).
    public let inlierRatio: Double?

    public init(index: Int, transform: simd_float3x3, correspondences: [Correspondence] = [], inlierRatio: Double? = nil) {
        self.index = index
        self.transform = transform
        self.correspondences = correspondences
        self.inlierRatio = inlierRatio
    }
}

/// Behind this: a Vision-registration estimator (#9) and an optical-flow estimator (#11).
/// Which one ships is decided by the phase-1 spike (#10), not assumed here.
///
/// `async` in this package, though ARCHITECTURE §4's snippet shows a synchronous `throws`
/// signature: Vision's request APIs (`ImageProcessingRequest.perform`, `TargetedImageRequestHandler.perform`)
/// are `async throws` with no synchronous equivalent, so a synchronous protocol here would
/// force every conformer to block a thread on Vision's dispatch queue. Documented as a
/// correction to the architecture doc via this PR, not silently — see #9's PR body.
public protocol MotionEstimator {
    /// `index` is carried on the returned `FrameMotion` for the caller's convenience — the
    /// estimator itself only ever sees two pixel buffers, so it always returns `index: 0`
    /// unless the caller overrides it (see `VisionRegistrationEstimator`'s doc comment).
    func estimate(frame: CVPixelBuffer, reference: CVPixelBuffer) async throws -> FrameMotion
}
