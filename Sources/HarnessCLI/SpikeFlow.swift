import CoreImage
import CoreVideo
import Foundation
import Vision
import simd

/// Spike-grade optical-flow estimator: `TrackOpticalFlowRequest`, sampled on a grid, fit
/// with RANSAC. It exists so #10 can measure flow's cost and accuracy. #11 builds the
/// production `OpticalFlowEstimator` (and decides how it handles masks, failures, and
/// confidence); nothing here is meant to survive that issue.
struct SpikeFlowEstimator {
    struct Result {
        let transform: simd_float3x3
        let inlierRatio: Double
        let sampleCount: Int
        let requestMs: Double
        let sampleMs: Double
        let fitMs: Double
    }

    static let gridSize = 32

    let accuracy: TrackOpticalFlowRequest.ComputationAccuracy
    /// Vision returns flow vectors scaled by an undocumented factor that depends on image
    /// size and accuracy level (0.17 to 0.50 observed; see decision 0001). Divide by this to
    /// get image pixels. Measure it with `calibrate` — 1 means "use Vision's numbers as is".
    var flowScale: Double = 1

    /// `frameMask` and `referenceMask` drop grid samples that land on a moving subject in
    /// either image. Pass `nil` for an unmasked estimate.
    func estimate(
        frame: CVPixelBuffer,
        reference: CVPixelBuffer,
        frameMask: SubjectMask? = nil,
        referenceMask: SubjectMask? = nil
    ) async throws -> Result {
        let width = Double(CVPixelBufferGetWidth(reference))
        let height = Double(CVPixelBufferGetHeight(reference))

        let handler = TargetedImageRequestHandler(source: frame, target: reference)
        let request = TrackOpticalFlowRequest()
        request.computationAccuracy = accuracy

        let requestStart = DispatchTime.now()
        guard let observation = try await handler.perform(request) else {
            throw SpikeError("optical flow returned no observation")
        }
        let requestMs = Self.milliseconds(since: requestStart)

        // Observed convention (verified on a known pure translation): flow is defined on the
        // REFERENCE (target) grid, and points toward where that content is in the FRAME.
        // `FrameMotion.transform` maps reference -> frame, so each grid point q gives the
        // pair (from: q, to: q + flow / flowScale).
        let sampleStart = DispatchTime.now()
        var pairs: [SpikeAffine.Pair] = []
        pairs.reserveCapacity(Self.gridSize * Self.gridSize)
        for gy in 0..<Self.gridSize {
            for gx in 0..<Self.gridSize {
                let nx = (Double(gx) + 0.5) / Double(Self.gridSize)
                let nyTop = (Double(gy) + 0.5) / Double(Self.gridSize)
                // Vision's normalized origin is bottom-left; image rows run top-down.
                let flow = observation.flow(at: NormalizedPoint(x: nx, y: 1 - nyTop))
                let referenceXY = SIMD2<Double>(nx * width, nyTop * height)
                let frameXY = SIMD2<Double>(
                    referenceXY.x + Double(flow.0) / flowScale,
                    referenceXY.y - Double(flow.1) / flowScale
                )
                if let referenceMask, referenceMask.contains(nx: nx, ny: nyTop) { continue }
                if let frameMask, frameMask.contains(nx: frameXY.x / width, ny: frameXY.y / height) { continue }
                pairs.append((from: referenceXY, to: frameXY))
            }
        }
        let sampleMs = Self.milliseconds(since: sampleStart)

        let fitStart = DispatchTime.now()
        // Inlier threshold scales with image size: ~0.15% of the long edge (about 1 px at
        // 720, 2.9 px at native).
        let threshold = max(width, height) * 0.0015
        guard let fit = SpikeAffine.ransac(pairs, threshold: threshold) else {
            throw SpikeError("could not fit a transform to \(pairs.count) flow samples")
        }
        let fitMs = Self.milliseconds(since: fitStart)

        return Result(
            transform: fit.transform,
            inlierRatio: fit.inlierRatio,
            sampleCount: pairs.count,
            requestMs: requestMs,
            sampleMs: sampleMs,
            fitMs: fitMs
        )
    }

    static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    /// Measures `flowScale` for one image size and accuracy level: shifts `reference` by a
    /// known amount, runs flow, and divides the median flow by the shift. Content does not
    /// matter (identical factors on synthetic circles and on a photograph), so this only
    /// needs to run once per size and level. Returns the scale and what the extra flow
    /// request cost, because production would pay that too.
    static func calibrate(
        reference: CVPixelBuffer,
        accuracy: TrackOpticalFlowRequest.ComputationAccuracy,
        context: CIContext
    ) async throws -> (scale: Double, milliseconds: Double) {
        let width = CVPixelBufferGetWidth(reference)
        let height = CVPixelBufferGetHeight(reference)
        let shift = Double(width) * 0.01
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let moved = CIImage(cvPixelBuffer: reference)
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: CGFloat(shift), y: 0))
            .cropped(to: extent)
        let shifted = try SpikeBuffers.render(moved, width: width, height: height, context: context)

        let start = DispatchTime.now()
        let handler = TargetedImageRequestHandler(source: shifted, target: reference)
        let request = TrackOpticalFlowRequest()
        request.computationAccuracy = accuracy
        guard let observation = try await handler.perform(request) else {
            throw SpikeError("calibration flow returned no observation")
        }
        var xs: [Float] = []
        for gy in 2..<14 {
            for gx in 2..<14 {
                let point = NormalizedPoint(x: (Double(gx) + 0.5) / 16, y: (Double(gy) + 0.5) / 16)
                xs.append(observation.flow(at: point).0)
            }
        }
        xs.sort()
        let ms = milliseconds(since: start)
        let scale = Double(xs[xs.count / 2]) / shift
        guard scale > 0.01 else { throw SpikeError("calibration found no flow (scale \(scale))") }
        return (scale, ms)
    }
}
