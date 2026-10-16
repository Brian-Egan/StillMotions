import CoreImage
import CoreVideo
import Foundation
import StillMotionsPipeline
import Vision
import simd

/// The residual-motion metric (PRD §1.2): mean displacement of background features between
/// consecutive OUTPUT frames, in pixels at the size of the frames measured.
///
/// Computed by optical flow, here in the harness, which is the only place correspondences are
/// guaranteed (decision 0001). Where the app ships registration, this measures a pipeline that is
/// not bit-identical to the shipping one; that divergence is the split design's known cost.
///
/// Background = the flow samples that agree with a RANSAC-fitted global motion, so a moving
/// subject is rejected as an outlier. Their mean displacement is the answer, so a camera that
/// still drifts shows up as a large number, and a perfectly still one as nearly zero.
struct ResidualMotionMeter {
    /// `.medium` is the cheapest level that stays accurate for sub-pixel motion in the spike's
    /// measurements; the metric needs small displacements, not large ones.
    var accuracy: TrackOpticalFlowRequest.ComputationAccuracy = .medium
    /// Vision's flow vectors are scaled by an undocumented factor (decision 0001), calibrated
    /// here with a shift of this fraction of the width, small because residuals are small.
    var calibrationShiftFraction = 0.004

    struct Result {
        let meanPixels: Double
        let pairs: Int
        let skippedPairs: Int
    }

    /// `next` yields the stabilized frames in playback order.
    func measure(next: () throws -> CVPixelBuffer?, context: CIContext = CIContext()) async throws -> Result {
        guard var previous = try next() else { return Result(meanPixels: 0, pairs: 0, skippedPairs: 0) }
        let calibration = try await SpikeFlowEstimator.calibrate(
            reference: previous, accuracy: accuracy, context: context, shiftFraction: calibrationShiftFraction
        )
        let estimator = SpikeFlowEstimator(accuracy: accuracy, flowScale: calibration.scale)

        var sum = 0.0
        var pairs = 0
        var skipped = 0
        while let current = try next() {
            do {
                let result = try await estimator.estimate(frame: current, reference: previous)
                sum += result.inlierMeanDisplacement
                pairs += 1
            } catch {
                skipped += 1
            }
            previous = current // holding it keeps the renderer's buffer pool from reusing it
        }
        return Result(meanPixels: pairs > 0 ? sum / Double(pairs) : 0, pairs: pairs, skippedPairs: skipped)
    }
}

/// Flow as a `MotionEstimator`, for `--estimator flow`. Decision 0001 keeps flow out of the app
/// and in the harness; this lets the harness run the whole pipeline on it.
final class FlowMotionEstimator: MotionEstimator, @unchecked Sendable {
    private let accuracy = TrackOpticalFlowRequest.ComputationAccuracy.veryHigh
    private let context = CIContext()
    private var calibration: Double?

    func estimate(frame: CVPixelBuffer, reference: CVPixelBuffer) async throws -> FrameMotion {
        if calibration == nil {
            calibration = try await SpikeFlowEstimator.calibrate(reference: reference, accuracy: accuracy, context: context).scale
        }
        let result = try await SpikeFlowEstimator(accuracy: accuracy, flowScale: calibration!).estimate(frame: frame, reference: reference)
        return FrameMotion(index: 0, transform: result.transform, inlierRatio: result.inlierRatio)
    }
}
