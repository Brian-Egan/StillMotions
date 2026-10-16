import CoreImage
import CoreVideo
import Foundation
import StillMotionsPipeline
import Vision
import simd

/// Whether Vision's optical flow runs on this machine at all.
///
/// It does not on GitHub's hosted macOS runners: the request fails with `memFullErr` ("failed to
/// analyze motion flow"), while registration works. Anything built on flow therefore cannot run
/// in CI, so the harness probes once and records residual motion as "not measured" instead of
/// failing the whole run. Locally it is measured, so a residual-motion regression is still caught
/// before a push (PRD R-23: CI guards correctness, local runs guard quality).
enum FlowAvailability {
    /// Set `STILLMOTIONS_SIMULATE_NO_FLOW=1` to take the no-flow path on a machine that has flow,
    /// which is how the CI behaviour is checked locally.
    static func probe() async -> Bool {
        if ProcessInfo.processInfo.environment["STILLMOTIONS_SIMULATE_NO_FLOW"] != nil { return false }
        func buffer(shift: Int) -> CVPixelBuffer? {
            var out: CVPixelBuffer?
            CVPixelBufferCreate(nil, 128, 128, kCVPixelFormatType_32BGRA, nil, &out)
            guard let buffer = out else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<128 {
                for x in 0..<128 {
                    // Deterministic texture, shifted horizontally.
                    let v = UInt8(truncatingIfNeeded: ((x + shift) &* 2654435761 &+ y &* 40503) >> 7)
                    let p = base + y * stride + x * 4
                    p[0] = v; p[1] = v &+ 40; p[2] = v &+ 80; p[3] = 255
                }
            }
            return buffer
        }
        guard let a = buffer(shift: 0), let b = buffer(shift: 3) else { return false }
        do {
            let request = TrackOpticalFlowRequest()
            request.computationAccuracy = .low
            _ = try await TargetedImageRequestHandler(source: b, target: a).perform(request)
            return true
        } catch {
            return false
        }
    }
}

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
    /// `.veryHigh`, the production default: the only level that reads a known 0.5 or 1.0 px
    /// residual within 20% at 720 px, the size this metric is measured at (#11). `.medium`, chosen
    /// earlier from large-transform fixtures, reads 0.5 px as 0.66.
    var accuracy: TrackOpticalFlowRequest.ComputationAccuracy = .veryHigh
    /// Vision's flow vectors are scaled by an undocumented factor (decision 0001), calibrated
    /// here with a shift of this fraction of the width, small because residuals are small.
    var calibrationShiftFraction = 0.004

    /// Names how this meter measures, recorded in the baseline so a mismatch is caught (#72).
    var identifier: String {
        let level: String
        switch accuracy {
        case .low: level = "low"
        case .medium: level = "medium"
        case .high: level = "high"
        case .veryHigh: level = "veryHigh"
        @unknown default: level = "unknown"
        }
        return "flow-\(level)"
    }

    struct Result {
        let meanPixels: Double
        let pairs: Int
        let skippedPairs: Int
    }

    /// `next` yields the stabilized frames in playback order.
    func measure(next: () throws -> CVPixelBuffer?) async throws -> Result {
        guard var previous = try next() else { return Result(meanPixels: 0, pairs: 0, skippedPairs: 0) }
        let estimator = OpticalFlowEstimator(configuration: .init(accuracy: accuracy, calibrationShiftFraction: calibrationShiftFraction))

        var sum = 0.0
        var pairs = 0
        var skipped = 0
        while let current = try next() {
            do {
                let result = try await estimator.estimateWithEvidence(frame: current, reference: previous)
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
/// and in the harness; this lets the harness run the whole pipeline on it. `.veryHigh` because a
/// whole-clip transform wants the most accurate level, unlike the residual meter's small shifts.
final class FlowMotionEstimator: MotionEstimator, @unchecked Sendable {
    private let estimator = OpticalFlowEstimator(configuration: .init(accuracy: .veryHigh))

    func estimate(frame: CVPixelBuffer, reference: CVPixelBuffer) async throws -> FrameMotion {
        try await estimator.estimate(frame: frame, reference: reference)
    }
}
