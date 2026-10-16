import CoreImage
import CoreVideo
import Foundation
import PipelineCore
import Vision
import simd

/// Motion estimation from `TrackOpticalFlowRequest`: sample the dense flow field on a grid,
/// treat each sample as a point pair, fit an affine transform with RANSAC.
///
/// This is the HARNESS-ONLY estimator (decision 0001, "split design"): the app ships
/// `VisionRegistrationEstimator`. Flow is here because it is the only source of
/// correspondences, which the residual-motion metric, outlier rejection and subject masking
/// (#19) all need. It is less accurate than registration on absolute transforms but is the
/// right tool for measuring small consecutive-frame residuals.
///
/// Three Vision behaviours shape this class (all measured in #10):
///
/// 1. **Flow vectors come back scaled** by an undocumented factor (about 0.17 to 0.50) that
///    depends on image size and `ComputationAccuracy`. The estimator calibrates it once per
///    (size, accuracy) with one extra flow request on a copy of the reference shifted by a
///    known amount, then divides it out.
/// 2. **Flow is defined on the reference grid** and points toward where that content is in the
///    frame, which matches `FrameMotion`'s reference-to-frame convention. Its y component uses
///    Vision's bottom-left origin, so y is flipped.
/// 3. **Apple: "very resource intensive, so perform only one request at a time."** Calls are
///    serialised here, and the observation is dropped as soon as the grid has been read.
///
/// Optical flow does not run on GitHub-hosted macOS runners. Callers that must work there
/// probe first (`FlowAvailability` in the harness) and tests skip when it is missing.
public final class OpticalFlowEstimator: MotionEstimator, @unchecked Sendable {
    public struct Configuration {
        /// Samples per axis. 32x32 = 1024 pairs: dense enough that a moving subject covering
        /// a few percent of the frame is a clear minority, cheap enough that RANSAC is
        /// negligible next to the flow request itself.
        public var gridSize: Int
        /// `.veryHigh`: the only level that reads a known sub-pixel residual within 20% at the
        /// metric's 720 px size (0.5 px -> 0.52, 1.0 px -> 1.00; `.medium` reads 0.66 and 1.09).
        /// It costs about twice `.medium` per frame, which a harness-only estimator can afford.
        /// Vision's flow has a noise floor that grows with image size (identical images read
        /// 0.1 px at 720 but 0.4 px at 1920 even at `.veryHigh`), so measure sub-pixel motion
        /// at 720 px, not native. See decision 0001's #11 outcome.
        public var accuracy: TrackOpticalFlowRequest.ComputationAccuracy
        /// RANSAC inlier distance as a fraction of the long edge: 0.15% is about 1 px at 720
        /// and 2.9 px at 1920. It has to be loose enough to absorb flow's ±15% nonlinearity
        /// and tight enough that a moving subject's samples fall outside it.
        public var inlierThresholdFraction: Double
        /// 300 three-pair models: with a 20% outlier share the chance of never drawing an
        /// all-inlier triple is negligible, and the cost is microseconds per iteration.
        public var ransacIterations: Int
        /// Size of the known shift used to measure the flow scale, as a fraction of width.
        /// Large enough to measure well above noise; the metric's residuals are small, so a
        /// caller measuring sub-pixel motion may pass something smaller.
        public var calibrationShiftFraction: Double

        public init(
            gridSize: Int = 32,
            accuracy: TrackOpticalFlowRequest.ComputationAccuracy = .veryHigh,
            inlierThresholdFraction: Double = 0.0015,
            ransacIterations: Int = 300,
            calibrationShiftFraction: Double = 0.01
        ) {
            self.gridSize = gridSize
            self.accuracy = accuracy
            self.inlierThresholdFraction = inlierThresholdFraction
            self.ransacIterations = ransacIterations
            self.calibrationShiftFraction = calibrationShiftFraction
        }
    }

    /// An estimate with the evidence behind it, which `FrameMotion` alone cannot carry.
    public struct Estimate {
        /// `correspondences` holds EVERY grid sample (inliers and outliers); `inlierRatio` is
        /// always non-nil.
        public let motion: FrameMotion
        /// Indices into `motion.correspondences` that agree with `motion.transform`.
        public let inlierIndices: [Int]
        /// Mean distance, in pixels of the frames given, between the two ends of each inlier
        /// pair: how far the background moved. This is the residual-motion measurement when
        /// the frames are consecutive stabilized output frames.
        public let inlierMeanDisplacement: Double
    }

    public let configuration: Configuration

    private let context = CIContext()
    private let lock = NSLock()
    private var scales: [CalibrationKey: Double] = [:]
    /// One flow request at a time, per Apple's guidance. A lock around an `await` is not
    /// allowed, so this is a simple FIFO gate built on a continuation queue.
    private let gate = FlowGate()

    private struct CalibrationKey: Hashable {
        let width: Int
        let height: Int
        let accuracy: Int
    }

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func estimate(frame: CVPixelBuffer, reference: CVPixelBuffer) async throws -> FrameMotion {
        try await estimateWithEvidence(frame: frame, reference: reference).motion
    }

    /// `frameMask` and `referenceMask` drop grid samples that land on a moving subject in the
    /// frame or in the reference (#19). A dropped sample is not returned as a correspondence and
    /// does not count toward `inlierRatio`. With no masks, nothing is dropped.
    public func estimateWithEvidence(
        frame: CVPixelBuffer, reference: CVPixelBuffer, frameMask: SubjectMask? = nil, referenceMask: SubjectMask? = nil
    ) async throws -> Estimate {
        await gate.acquire()
        do {
            let result = try await run(frame: frame, reference: reference, frameMask: frameMask, referenceMask: referenceMask)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    // MARK: - Implementation

    private func run(frame: CVPixelBuffer, reference: CVPixelBuffer, frameMask: SubjectMask?, referenceMask: SubjectMask?) async throws -> Estimate {
        let width = CVPixelBufferGetWidth(reference)
        let height = CVPixelBufferGetHeight(reference)
        guard width == CVPixelBufferGetWidth(frame), height == CVPixelBufferGetHeight(frame) else {
            throw OpticalFlowError.sizeMismatch
        }
        let scale = try await flowScale(for: reference)

        // Sample inside this scope so the observation (a full-resolution float field) is
        // released before the fit, keeping peak memory to one field.
        var pairs = try await sampledPairs(frame: frame, reference: reference, width: width, height: height, flowScale: scale)
        if frameMask != nil || referenceMask != nil {
            pairs = pairs.filter { pair in
                if let referenceMask, referenceMask.contains(nx: pair.from.x / Double(width), ny: pair.from.y / Double(height)) { return false }
                if let frameMask, frameMask.contains(nx: pair.to.x / Double(width), ny: pair.to.y / Double(height)) { return false }
                return true
            }
        }

        let threshold = Double(max(width, height)) * configuration.inlierThresholdFraction
        guard let fit = AffineRANSAC.fit(pairs, threshold: threshold, iterations: configuration.ransacIterations) else {
            throw OpticalFlowError.fitFailed(sampleCount: pairs.count)
        }
        let displacement = fit.inlierIndices
            .map { simd_distance(pairs[$0].from, pairs[$0].to) }
            .reduce(0, +) / Double(max(1, fit.inlierIndices.count))
        let correspondences = pairs.map {
            Correspondence(from: CGPoint(x: $0.from.x, y: $0.from.y), to: CGPoint(x: $0.to.x, y: $0.to.y))
        }
        return Estimate(
            motion: FrameMotion(index: 0, transform: fit.transform, correspondences: correspondences, inlierRatio: fit.inlierRatio),
            inlierIndices: fit.inlierIndices,
            inlierMeanDisplacement: displacement
        )
    }

    private func sampledPairs(
        frame: CVPixelBuffer, reference: CVPixelBuffer, width: Int, height: Int, flowScale: Double
    ) async throws -> [AffineRANSAC.Pair] {
        let request = TrackOpticalFlowRequest()
        request.computationAccuracy = configuration.accuracy
        guard let observation = try await TargetedImageRequestHandler(source: frame, target: reference).perform(request) else {
            throw OpticalFlowError.noObservation
        }
        let grid = configuration.gridSize
        var pairs: [AffineRANSAC.Pair] = []
        pairs.reserveCapacity(grid * grid)
        for gy in 0..<grid {
            for gx in 0..<grid {
                let nx = (Double(gx) + 0.5) / Double(grid)
                let nyTop = (Double(gy) + 0.5) / Double(grid)
                // Vision's normalized origin is bottom-left; image rows run top-down.
                let flow = observation.flow(at: NormalizedPoint(x: nx, y: 1 - nyTop))
                let referenceXY = SIMD2<Double>(nx * Double(width), nyTop * Double(height))
                let frameXY = SIMD2<Double>(
                    referenceXY.x + Double(flow.0) / flowScale,
                    referenceXY.y - Double(flow.1) / flowScale
                )
                pairs.append((from: referenceXY, to: frameXY))
            }
        }
        return pairs
    }

    private func flowScale(for reference: CVPixelBuffer) async throws -> Double {
        let key = CalibrationKey(
            width: CVPixelBufferGetWidth(reference),
            height: CVPixelBufferGetHeight(reference),
            accuracy: Self.accuracyRank(configuration.accuracy)
        )
        if let cached = lock.withLock({ scales[key] }) { return cached }

        let scale = try await calibrate(reference: reference)
        lock.withLock { scales[key] = scale }
        return scale
    }

    /// Shifts `reference` sideways by a known amount, runs flow, and divides the median flow by
    /// the shift. Content does not matter (identical factors on synthetic circles and a real
    /// photograph), so this runs once per size and level.
    private func calibrate(reference: CVPixelBuffer) async throws -> Double {
        let width = CVPixelBufferGetWidth(reference)
        let height = CVPixelBufferGetHeight(reference)
        let shift = Double(width) * configuration.calibrationShiftFraction
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let moved = CIImage(cvPixelBuffer: reference)
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: CGFloat(shift), y: 0))
            .cropped(to: extent)
        var out: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &out)
        guard let shifted = out else { throw OpticalFlowError.calibrationFailed(reason: "could not allocate a \(width)x\(height) buffer") }
        context.render(moved, to: shifted, bounds: extent, colorSpace: nil)

        let request = TrackOpticalFlowRequest()
        request.computationAccuracy = configuration.accuracy
        guard let observation = try await TargetedImageRequestHandler(source: shifted, target: reference).perform(request) else {
            throw OpticalFlowError.calibrationFailed(reason: "flow returned no observation")
        }
        // Central 12x12 of a 16x16 grid: avoids the border, where the clamped edge fill
        // would bias the median.
        var xs: [Float] = []
        for gy in 2..<14 {
            for gx in 2..<14 {
                xs.append(observation.flow(at: NormalizedPoint(x: (Double(gx) + 0.5) / 16, y: (Double(gy) + 0.5) / 16)).0)
            }
        }
        xs.sort()
        let scale = Double(xs[xs.count / 2]) / shift
        guard scale > 0.01 else { throw OpticalFlowError.calibrationFailed(reason: "no flow measured (scale \(scale))") }
        return scale
    }

    private static func accuracyRank(_ accuracy: TrackOpticalFlowRequest.ComputationAccuracy) -> Int {
        switch accuracy {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .veryHigh: return 3
        @unknown default: return -1
        }
    }
}

public enum OpticalFlowError: Error, CustomStringConvertible {
    case sizeMismatch
    case noObservation
    case fitFailed(sampleCount: Int)
    case calibrationFailed(reason: String)

    public var description: String {
        switch self {
        case .sizeMismatch: return "frame and reference differ in size"
        case .noObservation: return "optical flow returned no observation"
        case .fitFailed(let count): return "could not fit a transform to \(count) flow samples"
        case .calibrationFailed(let reason): return "flow scale calibration failed: \(reason)"
        }
    }
}

/// First-in-first-out mutual exclusion usable across `await`.
actor FlowGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
