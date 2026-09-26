import CoreVideo
import PipelineCore
import Vision
import simd

/// Cheap, one-call-per-frame motion estimation via Vision's whole-image homographic
/// registration. Fast enough for a live preview; the baseline the phase-1 spike (#10)
/// measures against optical flow. Returns a matrix with no correspondences and no
/// measurable confidence — `FrameMotion.inlierRatio` is `nil`, never fabricated as `1.0`
/// (decisions/0001-motion-estimation.md).
public struct VisionRegistrationEstimator: MotionEstimator {
    /// Bounds a plausible per-frame motion must fall within. Anything outside these is
    /// treated as a registration failure rather than passed downstream as nonsense — a
    /// tracker that has locked onto a moving subject or lost the frame entirely tends to
    /// produce wild rotation, scale, or translation, not a slightly-wrong small one.
    public struct PlausibilityBounds {
        public var maxRotation: Double
        public var scaleRange: ClosedRange<Double>
        public var maxTranslationFraction: Double

        public init(
            maxRotation: Double = .pi / 4,
            scaleRange: ClosedRange<Double> = 0.5...2.0,
            maxTranslationFraction: Double = 0.5
        ) {
            self.maxRotation = maxRotation
            self.scaleRange = scaleRange
            self.maxTranslationFraction = maxTranslationFraction
        }
    }

    public let bounds: PlausibilityBounds

    public init(bounds: PlausibilityBounds = PlausibilityBounds()) {
        self.bounds = bounds
    }

    /// Verified empirically against the synthetic fixtures (see #9's PR): calling the
    /// handler with `source: frame, target: reference` returns a `warpTransform` that maps
    /// REFERENCE coordinates onto FRAME coordinates (`pFrame ≈ warpTransform * pReference`)
    /// — exactly `FrameMotion`'s documented convention, with no inversion needed. Decision
    /// 0001's inline comment ("transform mapping frame onto reference") reads as the
    /// opposite of this and is corrected in this PR; decision 0002's "invert to produce
    /// corrections" is the one that's consistent with what Vision actually returns.
    public func estimate(frame: CVPixelBuffer, reference: CVPixelBuffer) async throws -> FrameMotion {
        let handler = TargetedImageRequestHandler(source: frame, target: reference)
        let observation = try await handler.perform(TrackHomographicImageRegistrationRequest())
        let transform = observation.warpTransform

        let width = CVPixelBufferGetWidth(reference)
        let height = CVPixelBufferGetHeight(reference)
        try Self.checkPlausibility(transform, frameWidth: width, frameHeight: height, bounds: bounds)

        return FrameMotion(index: 0, transform: transform, correspondences: [], inlierRatio: nil)
    }

    /// A free function of the matrix and frame size, not requiring Vision or a pixel
    /// buffer, so the bounds themselves are directly unit-testable rather than relying on
    /// Vision actually producing garbage on cue.
    public static func checkPlausibility(
        _ transform: simd_float3x3,
        frameWidth: Int,
        frameHeight: Int,
        bounds: PlausibilityBounds = PlausibilityBounds()
    ) throws {
        let linear = SIMD2<Double>(Double(transform.columns.0.x), Double(transform.columns.0.y))
        let scale = simd_length(linear)
        let rotation = atan2(Double(transform.columns.0.y), Double(transform.columns.0.x))
        let translation = SIMD2<Double>(Double(transform.columns.2.x), Double(transform.columns.2.y))
        let frameDiagonal = (Double(frameWidth) * Double(frameWidth) + Double(frameHeight) * Double(frameHeight)).squareRoot()

        guard bounds.scaleRange.contains(scale) else {
            throw MotionEstimationError.implausibleTransform(reason: "scale \(scale) outside \(bounds.scaleRange)")
        }
        guard abs(rotation) <= bounds.maxRotation else {
            throw MotionEstimationError.implausibleTransform(reason: "rotation \(rotation) rad exceeds ±\(bounds.maxRotation)")
        }
        let translationMagnitude = simd_length(translation)
        guard translationMagnitude <= bounds.maxTranslationFraction * frameDiagonal else {
            throw MotionEstimationError.implausibleTransform(reason: "translation \(translationMagnitude)px exceeds \(bounds.maxTranslationFraction) of frame diagonal")
        }
    }
}

public enum MotionEstimationError: Error, CustomStringConvertible {
    case implausibleTransform(reason: String)

    public var description: String {
        switch self {
        case .implausibleTransform(let reason):
            return "estimated transform rejected as implausible: \(reason)"
        }
    }
}
