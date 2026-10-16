import AVFoundation
import XCTest
@testable import HarnessCLI
@testable import StillMotionsPipeline

/// #20: stabilization failure detection as a pipeline RESULT. The verdict is computed once, in
/// `StabilizationAssessment`, and reaches the harness and the editor through `ClipAnalyzer.analyze`.
final class FailureDetectionTests: XCTestCase {
    // MARK: - The assessment (pure; runs everywhere)

    func testEveryReadingCarriesItsMeasuredValueAndLimit() {
        let metrics = ClipMetrics(cropRetention: 0.43, residualMotion: 2.5, loopSeamRatio: 3.1)
        let assessment = metrics.assessment

        XCTAssertEqual(assessment.readings.map(\.signal), FailureSignal.allCases, "always one reading per signal, in a fixed order")
        XCTAssertEqual(assessment.reading(for: .cropRetention).value, 0.43)
        XCTAssertEqual(assessment.reading(for: .residualMotion).value, 2.5)
        XCTAssertEqual(assessment.reading(for: .loopSeam).value, 3.1)
        XCTAssertEqual(assessment.reading(for: .cropRetention).limit, QualityThresholds.minimumCropRetention)
        XCTAssertEqual(assessment.reading(for: .residualMotion).limit, QualityThresholds.maximumResidualMotion)
        XCTAssertEqual(assessment.reading(for: .loopSeam).limit, QualityThresholds.maximumLoopSeamRatio)
        XCTAssertEqual(assessment.failedSignals, [.cropRetention, .residualMotion, .loopSeam])
        XCTAssertTrue(assessment.isFailure)
    }

    func testAPassingClipStillCarriesItsValues() {
        let assessment = ClipMetrics(cropRetention: 0.9, residualMotion: 0.3, loopSeamRatio: 1.0).assessment
        XCTAssertFalse(assessment.isFailure)
        XCTAssertEqual(assessment.failedSignals, [])
        XCTAssertEqual(assessment.readings.compactMap(\.value), [0.9, 0.3, 1.0], "values are reported whether or not they failed")
    }

    func testThresholdBoundariesMatchThePRD() {
        // Crop retention must be AT LEAST 60%: exactly 60% passes.
        XCTAssertFalse(ClipMetrics(cropRetention: 0.60).assessment.isFailure)
        XCTAssertTrue(ClipMetrics(cropRetention: 0.5999).assessment.isFailure)
        // Residual motion must be BELOW 1.0 px: exactly 1.0 fails.
        XCTAssertTrue(ClipMetrics(cropRetention: 1, residualMotion: 1.0).assessment.isFailure)
        XCTAssertFalse(ClipMetrics(cropRetention: 1, residualMotion: 0.9999).assessment.isFailure)
        // The loop seam must be AT MOST 1.5x: exactly 1.5 passes.
        XCTAssertFalse(ClipMetrics(cropRetention: 1, loopSeamRatio: 1.5).assessment.isFailure)
        XCTAssertTrue(ClipMetrics(cropRetention: 1, loopSeamRatio: 1.5001).assessment.isFailure)
    }

    func testAnUnmeasuredSignalIsReportedAsUnmeasuredNotAsAFailure() {
        let assessment = ClipMetrics(cropRetention: 0.8).assessment
        XCTAssertNil(assessment.reading(for: .residualMotion).value)
        XCTAssertNil(assessment.reading(for: .loopSeam).value)
        XCTAssertFalse(assessment.reading(for: .residualMotion).failed)
        XCTAssertFalse(assessment.isFailure)
    }

    func testFailuresAndPassedAreDerivedFromTheAssessment() {
        for metrics in [
            ClipMetrics(cropRetention: 0.3, residualMotion: 0.2, loopSeamRatio: 4),
            ClipMetrics(cropRetention: 0.9, residualMotion: 3),
            ClipMetrics(cropRetention: 0.9),
        ] {
            XCTAssertEqual(metrics.failures, metrics.assessment.failedSignals)
            XCTAssertEqual(metrics.passed, !metrics.assessment.isFailure)
        }
    }

    func testAssessmentRoundTripsThroughJSON() throws {
        let assessment = ClipMetrics(cropRetention: 0.5, residualMotion: nil, loopSeamRatio: 2).assessment
        let decoded = try JSONDecoder().decode(StabilizationAssessment.self, from: JSONEncoder().encode(assessment))
        XCTAssertEqual(decoded, assessment)
    }

    // MARK: - The pipeline returns failure as a result

    /// A solver that finds nothing to crop to, as for a clip that has no common area.
    private struct NoCommonAreaSolver: CameraPathSolver {
        func solve(motion: [FrameMotion], frameSize: CGSize) throws -> CameraPath {
            throw CameraPathError.noCommonRegion(frameIndex: 7)
        }
    }

    func testAClipWithNothingToCropToIsReportedNotThrown() async throws {
        let url = MotionEstimationTests.fixturesDirectory.appendingPathComponent("translate-shake.mov")
        let result = try await ClipAnalyzer.analyze(
            movieURL: url, referenceIndex: 0, estimator: VisionRegistrationEstimator(), solver: NoCommonAreaSolver()
        )

        XCTAssertFalse(result.stabilized)
        XCTAssertNotNil(result.unstabilizedReason)
        XCTAssertTrue(result.assessment.isFailure)
        XCTAssertEqual(result.assessment.reading(for: .cropRetention).value, 0)
        XCTAssertTrue(result.assessment.reading(for: .cropRetention).failed)
        // Still usable: the unstabilized path shows the clip as shot, so the editor can preview it.
        XCTAssertEqual(result.path.corrections.count, result.motion.motion.count)
        XCTAssertEqual(result.path.crop, CGRect(origin: .zero, size: result.motion.size))
        XCTAssertTrue(result.path.corrections.allSatisfy { $0 == matrix_identity_float3x3 })
    }

    // MARK: - Synthetic fixtures

    /// Registration with chained estimation, as shipped, plus the harness's residual meter when
    /// flow is available.
    static func analysis(_ fixture: String, withResidual: Bool) async throws -> ClipAnalysis {
        let url = MotionEstimationTests.fixturesDirectory.appendingPathComponent("\(fixture).mov")
        let truth = try FixtureTruth.load(from: MotionEstimationTests.fixturesDirectory.appendingPathComponent("\(fixture).truth.json"))
        return try await ClipAnalyzer.analyze(
            movieURL: url, referenceIndex: truth.referenceFrameIndex, estimator: VisionRegistrationEstimator(),
            residualMotion: withResidual
                ? { path in
                    let asset = AVURLAsset(url: url)
                    let track = try await asset.loadTracks(withMediaType: .video)[0]
                    let next = try StabilizedRenderer().makeProducer(
                        frames: try FrameSequence.make(asset: asset, track: track), corrections: path.corrections,
                        crop: path.crop, outputSize: OutputSize.size(forCrop: path.crop, longEdge: 720)
                    )
                    return try await ResidualMotionMeter().measure(next: next).meanPixels
                }
                : nil
        )
    }

    func testCleanCameraMotionIsNotFlagged() async throws {
        let flow = await FlowAvailability.probe()
        for fixture in ["translate-shake", "rotate"] {
            let result = try await Self.analysis(fixture, withResidual: flow)
            XCTAssertFalse(result.assessment.isFailure, "\(fixture) must not be flagged: \(result.assessment.readings)")
            XCTAssertTrue(result.stabilized)
        }
    }

    /// #20 expected the `parallax` fixture to be flagged. It is not, and cannot be by these three
    /// signals: crop retention, residual motion and the loop seam all describe the DOMINANT layer,
    /// which one homography stabilizes well, while the near layer's jitter is invisible to them
    /// (residual motion is measured on the RANSAC inliers, i.e. the background). Flagging it
    /// needs a signal that sees the minority layer, such as the optical-flow inlier ratio, which
    /// the issue rules out as a failure input (it is nil under registration). This test records
    /// what is measured so a change to that is deliberate. See the #20 PR and decision 0009.
    func testParallaxIsNotFlaggedBecauseTheSignalsOnlySeeTheDominantLayer() async throws {
        let flow = await FlowAvailability.probe()
        let result = try await Self.analysis("parallax", withResidual: flow)
        XCTAssertFalse(result.assessment.isFailure, "if this starts failing, the signals gained the ability to see parallax: update decision 0009")
        XCTAssertGreaterThan(result.assessment.reading(for: .cropRetention).value ?? 0, 0.9)
    }

    /// The harness and the pipeline must agree for every fixture (#20): the harness now takes its
    /// metrics from `ClipAnalyzer.analyze`, and this proves its report says what the pipeline says.
    func testHarnessVerdictEqualsThePipelineVerdictForEveryFixture() async throws {
        let flow = await FlowAvailability.probe()
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("failure-detection-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let exit = try await HarnessRunner.run(arguments: [
            "--fixtures", MotionEstimationTests.fixturesDirectory.path, "--out", out.path, "--metrics-only",
        ])
        XCTAssertEqual(exit, 0)
        let summary = try JSONDecoder().decode(HarnessRunner.Summary.self, from: Data(contentsOf: out.appendingPathComponent("summary.json")))
        XCTAssertGreaterThanOrEqual(summary.clips.count, 8)

        for report in summary.clips {
            let pipeline = try await Self.analysis(report.name, withResidual: flow)
            XCTAssertEqual(report.metrics.cropRetention, pipeline.metrics.cropRetention, accuracy: 1e-9, "\(report.name) crop")
            XCTAssertEqual(report.metrics.loopSeamRatio ?? -1, pipeline.metrics.loopSeamRatio ?? -1, accuracy: 1e-9, "\(report.name) seam")
            XCTAssertEqual(report.metrics.residualMotion ?? -1, pipeline.metrics.residualMotion ?? -1, accuracy: 1e-9, "\(report.name) residual")
            XCTAssertEqual(report.failures, pipeline.assessment.failedSignals.map(\.rawValue), "\(report.name): harness and pipeline disagree")
        }
    }
}
