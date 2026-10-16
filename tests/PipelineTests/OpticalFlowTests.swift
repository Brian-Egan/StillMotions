import CoreImage
import CoreVideo
import XCTest
import simd
@testable import HarnessCLI
@testable import StillMotionsPipeline

/// #11. Optical flow is the HARNESS estimator (decision 0001), so what matters is that it
/// measures small consecutive-frame residuals well and rejects a moving subject, not that it
/// beats registration on absolute transforms (it does not; see the #11 comment).
///
/// The Vision-backed tests skip where flow is unavailable (GitHub-hosted macOS runners fail
/// with `memFullErr`). `AffineRANSAC` has its own pure tests that run everywhere.
final class OpticalFlowTests: XCTestCase {
    static let fixturesDirectory = MotionEstimationTests.fixturesDirectory

    private func requireFlow() async throws {
        let available = await FlowAvailability.probe()
        try XCTSkipUnless(available, "Vision optical flow is unavailable on this machine")
    }

    // MARK: - AffineRANSAC (runs in CI)

    func testRANSACRecoversTheMajorityMotionAndRejectsOutliers() throws {
        // 70 background pairs translating by (3, -2); 30 "subject" pairs moving by (40, 25).
        var pairs: [AffineRANSAC.Pair] = []
        var rng = SystemRandomNumberGenerator()
        for i in 0..<100 {
            let from = SIMD2<Double>(Double.random(in: 0...1000, using: &rng), Double.random(in: 0...600, using: &rng))
            let move = i < 70 ? SIMD2<Double>(3, -2) : SIMD2<Double>(40, 25)
            pairs.append((from: from, to: from + move))
        }
        let fit = try XCTUnwrap(AffineRANSAC.fit(pairs, threshold: 1.0))

        XCTAssertEqual(fit.inlierRatio, 0.7, accuracy: 0.001)
        XCTAssertEqual(fit.inlierIndices, Array(0..<70), "exactly the background pairs are inliers")
        XCTAssertEqual(Double(fit.transform.columns.2.x), 3, accuracy: 0.01)
        XCTAssertEqual(Double(fit.transform.columns.2.y), -2, accuracy: 0.01)
    }

    func testRANSACIsDeterministic() throws {
        let pairs: [AffineRANSAC.Pair] = (0..<60).map { i in
            let from = SIMD2<Double>(Double(i * 13 % 97), Double(i * 29 % 89))
            return (from: from, to: from + (i % 5 == 0 ? SIMD2(20, 20) : SIMD2(1, 1)))
        }
        let a = try XCTUnwrap(AffineRANSAC.fit(pairs, threshold: 0.5))
        let b = try XCTUnwrap(AffineRANSAC.fit(pairs, threshold: 0.5))
        XCTAssertEqual(a.inlierIndices, b.inlierIndices)
        XCTAssertEqual(a.transform, b.transform)
    }

    func testRANSACReturnsNilWithTooFewOrDegeneratePairs() {
        XCTAssertNil(AffineRANSAC.fit([(from: .zero, to: .zero)], threshold: 1))
        let collinear: [AffineRANSAC.Pair] = (0..<10).map { (from: SIMD2(Double($0), Double($0)), to: SIMD2(Double($0), Double($0))) }
        XCTAssertNil(AffineRANSAC.fit(collinear, threshold: 1))
    }

    // MARK: - Residual motion (the metric's regime)

    /// Shifting a real fixture frame by a known sub-pixel amount and measuring it back. This is
    /// what the residual-motion metric does to consecutive stabilized frames, and the harness
    /// measures it at 720 px, so 720 px is what is asserted. Native size is printed, not
    /// asserted: Vision's flow has a noise floor there (0.4 px on identical images) that makes
    /// sub-pixel readings unreliable. See decision 0001's #11 outcome.
    func testRecoversKnownSubPixelResidualWithin20PercentAt720() async throws {
        try await requireFlow()
        let frames = try await MotionEstimationTests.loadFrames(fixture: "translate-linear", indices: [0])
        let native = frames[0].pixelBuffer
        let context = CIContext()
        let small = try SpikeBuffers.scaled(native, longEdge: 720, context: context).buffer
        var report = "size,truthPx,measuredPx,errorPct,inlierRatio\n"

        for (label, buffer) in [("720", small), ("native (not asserted)", native)] {
            let estimator = OpticalFlowEstimator(configuration: .init(calibrationShiftFraction: 0.004))
            for truth in [0.5, 1.0] {
                let shifted = try Self.shifted(buffer, dx: truth, dy: 0, context: context)
                let estimate = try await estimator.estimateWithEvidence(frame: shifted, reference: buffer)
                let measured = estimate.inlierMeanDisplacement
                let errorPct = abs(measured - truth) / truth * 100
                report += "\(label),\(truth),\(String(format: "%.3f", measured)),\(String(format: "%.1f", errorPct)),\(String(format: "%.2f", estimate.motion.inlierRatio ?? -1))\n"
                if label == "720" {
                    XCTAssertEqual(measured, truth, accuracy: truth * 0.20, "720: measured \(measured) px for a true \(truth) px shift")
                }
            }
        }
        print("\n=== Residual recovery (OpticalFlowEstimator, default .veryHigh) ===\n\(report)")
    }

    // MARK: - Correspondences, inlier ratio, subject rejection

    func testInlierRatioIsMeasuredAndDropsWithAMovingSubject() async throws {
        try await requireFlow()
        let estimator = OpticalFlowEstimator()

        let shake = try await MotionEstimationTests.loadFrames(fixture: "translate-shake", indices: [0, 60])
        let shakeEstimate = try await estimator.estimateWithEvidence(frame: shake[1].pixelBuffer, reference: shake[0].pixelBuffer)
        let shakeRatio = try XCTUnwrap(shakeEstimate.motion.inlierRatio, "flow must report a real inlier ratio, never nil")
        XCTAssertEqual(shakeEstimate.motion.correspondences.count, 32 * 32, "default grid is 32x32")

        let scenario = try Self.largeSubjectScenario()
        let frames = try await scenario.loadFrames([0, 60])
        let subjectEstimate = try await estimator.estimateWithEvidence(frame: frames[60]!, reference: frames[0]!)
        let subjectRatio = try XCTUnwrap(subjectEstimate.motion.inlierRatio)

        print("\n=== inlierRatio: translate-shake \(String(format: "%.2f", shakeRatio)), moving-subject-large \(String(format: "%.2f", subjectRatio)) ===")
        XCTAssertLessThan(subjectRatio, shakeRatio - 0.05, "a large moving subject must measurably lower the inlier ratio")
    }

    func testRANSACInliersClusterInTheBackground() async throws {
        try await requireFlow()
        let scenario = try Self.largeSubjectScenario()
        let frames = try await scenario.loadFrames([0, 60])
        let referenceSubject = try XCTUnwrap(scenario.oracleMask)(0)

        let estimate = try await OpticalFlowEstimator().estimateWithEvidence(frame: frames[60]!, reference: frames[0]!)
        let width = Double(CVPixelBufferGetWidth(frames[0]!))
        let height = Double(CVPixelBufferGetHeight(frames[0]!))
        func onSubject(_ index: Int) -> Bool {
            let p = estimate.motion.correspondences[index].from
            return referenceSubject.contains(nx: Double(p.x) / width, ny: Double(p.y) / height)
        }

        let inlierSet = Set(estimate.inlierIndices)
        let subjectSamples = estimate.motion.correspondences.indices.filter(onSubject)
        let subjectInliers = subjectSamples.filter(inlierSet.contains)
        let inliersOnSubject = estimate.inlierIndices.filter(onSubject)

        print("\n=== subject rejection: \(subjectSamples.count) samples on the subject, \(subjectInliers.count) of them inliers; \(estimate.inlierIndices.count) inliers in total, \(inliersOnSubject.count) on the subject ===")
        // The subject is a flat-coloured square, so flow in its interior has nothing to lock onto
        // (the aperture problem) and some interior samples come back looking like background
        // motion and survive. What must hold is that the subject is strongly depleted among the
        // inliers compared with the background, and that inliers are overwhelmingly background.
        let backgroundSamples = estimate.motion.correspondences.count - subjectSamples.count
        let backgroundInliers = estimate.inlierIndices.count - inliersOnSubject.count
        let subjectRate = Double(subjectInliers.count) / Double(subjectSamples.count)
        let backgroundRate = Double(backgroundInliers) / Double(backgroundSamples)
        XCTAssertGreaterThan(subjectSamples.count, 50, "the subject should cover a meaningful part of the grid")
        XCTAssertGreaterThan(backgroundRate, 0.8, "the background should be accepted")
        XCTAssertLessThan(subjectRate, backgroundRate / 2, "the subject must be rejected at less than half the background's acceptance rate")
        XCTAssertLessThan(Double(inliersOnSubject.count) / Double(estimate.inlierIndices.count), 0.10, "inliers must be background")
    }

    // MARK: - Memory (recorded, not asserted: a Mac is a relative signal only)

    func testRecordsPeakMemoryAt720AndNative() async throws {
        try await requireFlow()
        let frames = try await MotionEstimationTests.loadFrames(fixture: "translate-shake", indices: [0, 30])
        let context = CIContext()
        for (label, size) in [("720", 720), ("native", 1920)] {
            let reference = try SpikeBuffers.scaled(frames[0].pixelBuffer, longEdge: size, context: context).buffer
            let frame = try SpikeBuffers.scaled(frames[1].pixelBuffer, longEdge: size, context: context).buffer
            let estimator = OpticalFlowEstimator()
            _ = try await estimator.estimate(frame: frame, reference: reference) // calibrates
            let sampler = FootprintSampler()
            sampler.start()
            for _ in 0..<5 { _ = try await estimator.estimate(frame: frame, reference: reference) }
            let growth = sampler.stop()
            print("peak memory growth, \(label): \(String(format: "%.1f", growth)) MB")
            XCTAssertLessThan(growth, 200, "\(label): flow memory above 200 MB must be flagged in the PR (#11)")
        }
    }

    // MARK: - Helpers

    private static func largeSubjectScenario() throws -> BenchmarkEstimators.Scenario {
        let truth = try FixtureTruth.load(from: fixturesDirectory.appendingPathComponent("moving-subject.truth.json"))
        return try BenchmarkEstimators.largeSubjectScenario(movingSubjectTruth: truth, context: CIContext())
    }

    /// `buffer` content moved by (dx, dy) pixels with bilinear resampling; edges are clamped.
    private static func shifted(_ buffer: CVPixelBuffer, dx: Double, dy: Double, context: CIContext) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let moved = CIImage(cvPixelBuffer: buffer)
            .clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy)))
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        return try SpikeBuffers.render(moved, width: width, height: height, context: context)
    }
}
