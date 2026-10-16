import XCTest
import simd
@testable import StillMotionsPipeline

final class ClipAnalyzerTests: XCTestCase {
    static let cameraFixtures = ["translate-linear", "translate-shake", "rotate", "scale", "combined", "periodic"]

    func movie(_ name: String) -> URL {
        CameraPathTests.fixturesDirectory.appendingPathComponent("\(name).mov")
    }

    /// Recovered-vs-truth error per frame, in native pixels, relative to `referenceIndex`.
    func errors(_ result: ClipAnalyzer.MotionResult, fixture: String, referenceIndex: Int) throws -> [Double] {
        let truth = try FixtureTruth.load(from: CameraPathTests.fixturesDirectory.appendingPathComponent("\(fixture).truth.json"))
        let inverse = truth.frames[referenceIndex].matrix.inverse
        return result.motion.map { frame in
            SpikeLikeAccuracy.rms(
                recovered: frame.transform, truth: truth.frames[frame.index].matrix * inverse,
                frameSize: CGSize(width: truth.width, height: truth.height)
            )
        }
    }

    // MARK: - Accuracy on the synthetic clips (chaining must not hurt the easy cases)

    func testChainedEstimationStaysWithinTheAccuracyBarOnEveryCameraFixture() async throws {
        var report = "fixture,strategy,meanRMS,maxRMS,failures\n"
        for fixture in Self.cameraFixtures {
            for strategy in [ClipAnalyzer.Strategy.reference, .chained] {
                let result = try await ClipAnalyzer.estimateMotion(
                    movieURL: movie(fixture), referenceIndex: 0, estimator: VisionRegistrationEstimator(), strategy: strategy
                )
                let e = try errors(result, fixture: fixture, referenceIndex: 0)
                let mean = e.reduce(0, +) / Double(e.count), worst = e.max()!
                report += String(format: "%@,%@,%.3f,%.3f,%d\n", fixture, strategy.rawValue, mean, worst, result.estimationFailures)
                XCTAssertEqual(result.motion.count, 90, "\(fixture) \(strategy)")
                if strategy == .chained {
                    // Chaining trades jitter for DRIFT. Vision's registration under-estimates steps
                    // smaller than about 2 px by 0.15 to 0.3 px each (and is unbiased above that), so
                    // slow motion accumulates a little error every frame. Measured worst case on
                    // these clips is 0.23 px per frame (the 1 to 2 px steps of `periodic`); the
                    // bound here is on that rate, not on the direct strategy's 0.75 px bar.
                    for (frame, error) in e.enumerated() {
                        XCTAssertLessThan(error, 0.3 * Double(frame) + 0.5, "\(fixture) frame \(frame): drift faster than 0.3 px per frame")
                    }
                    XCTAssertLessThan(worst, 10, "\(fixture): total drift over the clip should stay under 10 px (0.5% of the width)")
                    XCTAssertEqual(result.estimationFailures, 0, fixture)
                }
            }
        }
        print("\n=== recovered-vs-truth RMS (native px), every frame ===\n\(report)")
    }

    func testChainingBackwardsFromAMidClipReference() async throws {
        // The reference is usually mid-clip, so half the frames chain BACKWARDS to it.
        let result = try await ClipAnalyzer.estimateMotion(
            movieURL: movie("combined"), referenceIndex: 45, estimator: VisionRegistrationEstimator(), strategy: .chained
        )
        XCTAssertEqual(result.motion.count, 90)
        XCTAssertEqual(result.motion[45].transform, matrix_identity_float3x3)
        let e = try errors(result, fixture: "combined", referenceIndex: 45)
        for (frame, error) in e.enumerated() {
            XCTAssertLessThan(error, 0.3 * Double(abs(frame - 45)) + 0.5, "frame \(frame): drift faster than 0.3 px per frame from the reference")
        }
        XCTAssertEqual(result.estimationFailures, 0)
    }

    func testReferenceStrategyStillWorks() async throws {
        let result = try await ClipAnalyzer.estimateMotion(
            movieURL: movie("translate-linear"), referenceIndex: 30, estimator: VisionRegistrationEstimator(), strategy: .reference
        )
        let e = try errors(result, fixture: "translate-linear", referenceIndex: 30)
        XCTAssertLessThan(e.max()!, 0.75)
    }

    // MARK: - Failure handling

    /// An estimator that fails on chosen calls, to prove one bad step neither stops the clip nor
    /// corrupts the frames after it.
    final class FlakyEstimator: MotionEstimator, @unchecked Sendable {
        let inner = VisionRegistrationEstimator()
        let failOn: Set<Int>
        private var calls = 0
        init(failOn: Set<Int>) { self.failOn = failOn }
        func estimate(frame: CVPixelBuffer, reference: CVPixelBuffer) async throws -> FrameMotion {
            calls += 1
            if failOn.contains(calls) { throw MotionEstimationError.implausibleTransform(reason: "injected") }
            return try await inner.estimate(frame: frame, reference: reference)
        }
    }

    func testAFailedStepIsCountedAndTheClipContinues() async throws {
        let clean = try await ClipAnalyzer.estimateMotion(
            movieURL: movie("translate-linear"), referenceIndex: 0, estimator: VisionRegistrationEstimator(), strategy: .chained
        )
        let result = try await ClipAnalyzer.estimateMotion(
            movieURL: movie("translate-linear"), referenceIndex: 0, estimator: FlakyEstimator(failOn: [10, 11]), strategy: .chained
        )
        XCTAssertEqual(result.estimationFailures, 2)
        XCTAssertEqual(result.motion.count, 90, "every frame still gets a transform")
        // A failed step means "no motion assumed". The clip carries on, and from then on every
        // frame is offset by just the two lost steps (about 0.45 px each) from the clean run:
        // no jump, no runaway.
        for index in 12..<90 {
            let a = result.motion[index].transform, b = clean.motion[index].transform
            XCTAssertEqual(a[2][0], b[2][0], accuracy: 2.0, "frame \(index) strayed from the clean run")
        }
        XCTAssertEqual(result.motion[5].transform[2][0], clean.motion[5].transform[2][0], accuracy: 0.01, "frames before the failure are untouched")
    }

    func testStepPlausibilityRejectsWhatNeighbouringFramesCannotDo() throws {
        let bounds = ClipAnalyzer.stepPlausibility
        func check(_ m: simd_float3x3) throws {
            try VisionRegistrationEstimator.checkPlausibility(m, frameWidth: 960, frameHeight: 720, bounds: bounds)
        }
        // 10 px, 1 degree, 1% zoom: an ordinary step.
        let a: Float = 1.01 * cos(.pi / 180), b: Float = 1.01 * sin(.pi / 180)
        XCTAssertNoThrow(try check(simd_float3x3(rows: [SIMD3(a, -b, 10), SIMD3(b, a, 3), SIMD3(0, 0, 1)])))
        // Scale 1.5 between neighbouring frames: not a camera, an estimation failure.
        XCTAssertThrowsError(try check(simd_float3x3(rows: [SIMD3(1.5, 0, 0), SIMD3(0, 1.5, 0), SIMD3(0, 0, 1)])))
        // 21 degrees.
        let c: Float = cos(21 * .pi / 180), d: Float = sin(21 * .pi / 180)
        XCTAssertThrowsError(try check(simd_float3x3(rows: [SIMD3(c, -d, 0), SIMD3(d, c, 0), SIMD3(0, 0, 1)])))
    }
}

/// The 5x5-grid RMS of `MotionEstimationTests.rms`, for comparing transforms (a copy, because that
/// one lives on another test class).
enum SpikeLikeAccuracy {
    static func rms(recovered: simd_float3x3, truth: simd_float3x3, frameSize: CGSize) -> Double {
        MotionEstimationTests.rms(recovered: recovered, truth: truth, frameSize: frameSize)
    }
}
