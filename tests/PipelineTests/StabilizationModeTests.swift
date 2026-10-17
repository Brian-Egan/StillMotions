import XCTest
import simd
@testable import CameraPath
@testable import StillMotionsPipeline

/// #84: Off, Smooth and Locked. Same footage, three target camera paths.
final class StabilizationModeTests: XCTestCase {
    static let frameSize = CGSize(width: 960, height: 540)

    /// A camera that shakes by up to about 6 px (a fixed pseudo-random pattern) while drifting right
    /// 60 px over the clip. `T` for each frame maps reference coordinates onto that frame.
    static func shakyDriftingMotion(frames: Int = 60) -> [FrameMotion] {
        var rng = SplitMix64Test(seed: 42)
        return (0..<frames).map { i in
            let drift = 60.0 * Double(i) / Double(frames - 1)
            let shakeX = (rng.unit() - 0.5) * 12, shakeY = (rng.unit() - 0.5) * 12
            return FrameMotion(index: i, transform: translation(drift + shakeX, shakeY))
        }
    }

    static func translation(_ x: Double, _ y: Double) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0), SIMD3<Float>(Float(x), Float(y), 1)))
    }

    /// Where a reference point ends up in the output of a path: `correction * T * p`.
    static func outputPositions(_ path: CameraPath, _ motion: [FrameMotion], point: SIMD2<Float> = SIMD2(480, 270)) -> [SIMD2<Float>] {
        zip(path.corrections, motion).map { correction, frame in
            let p = correction * (frame.transform * SIMD3<Float>(point.x, point.y, 1))
            return SIMD2(p.x / p.z, p.y / p.z)
        }
    }

    /// Mean distance between consecutive output positions: how much the picture still moves.
    static func jitter(_ positions: [SIMD2<Float>]) -> Double {
        let steps = zip(positions.dropFirst(), positions).map { Double(simd_distance($0, $1)) }
        return steps.reduce(0, +) / Double(steps.count)
    }

    // MARK: - Solvers

    func testOffLeavesTheFramesAsShot() throws {
        let motion = Self.shakyDriftingMotion()
        let path = try OriginalPathSolver().solve(motion: motion, frameSize: Self.frameSize)
        XCTAssertEqual(path.corrections.count, motion.count)
        XCTAssertTrue(path.corrections.allSatisfy { $0 == matrix_identity_float3x3 })
        XCTAssertEqual(path.crop, CGRect(origin: .zero, size: Self.frameSize))
        XCTAssertEqual(path.cropRetention, 1)
    }

    func testEachModeUsesItsOwnSolver() {
        XCTAssertTrue(StabilizationMode.off.solver is OriginalPathSolver)
        XCTAssertTrue(StabilizationMode.smooth.solver is SmoothedPathSolver)
        XCTAssertTrue(StabilizationMode.locked.solver is WarpToReferenceSolver)
        XCTAssertEqual(StabilizationMode.default, .locked)
        XCTAssertEqual(StabilizationMode.allCases.map(\.displayName), ["Off", "Smooth", "Locked"])
    }

    func testCropKeptGoesOffThenSmoothThenLocked() throws {
        let motion = Self.shakyDriftingMotion()
        let off = try StabilizationMode.off.solver.solve(motion: motion, frameSize: Self.frameSize)
        let smooth = try StabilizationMode.smooth.solver.solve(motion: motion, frameSize: Self.frameSize)
        let locked = try StabilizationMode.locked.solver.solve(motion: motion, frameSize: Self.frameSize)
        XCTAssertGreaterThan(off.cropRetention, smooth.cropRetention - 1e-9)
        XCTAssertGreaterThan(smooth.cropRetention, locked.cropRetention, "Smooth must keep more of the frame than Locked")
        XCTAssertLessThan(locked.cropRetention, 0.95, "the drift should cost Locked something, or this test proves nothing")
    }

    func testLeftoverMotionGoesLockedThenSmoothThenOff() throws {
        let motion = Self.shakyDriftingMotion()
        func jitter(_ mode: StabilizationMode) throws -> Double {
            Self.jitter(Self.outputPositions(try mode.solver.solve(motion: motion, frameSize: Self.frameSize), motion))
        }
        let off = try jitter(.off), smooth = try jitter(.smooth), locked = try jitter(.locked)
        XCTAssertLessThan(locked, 1e-3, "Locked pins the picture still")
        XCTAssertGreaterThan(smooth, locked)
        XCTAssertLessThan(smooth, off * 0.6, "Smooth must remove most of the shake: \(smooth) px vs \(off) px as shot")
    }

    func testSmoothKeepsTheSlowDriftAndRemovesTheShake() throws {
        let motion = Self.shakyDriftingMotion()
        let path = try SmoothedPathSolver().solve(motion: motion, frameSize: Self.frameSize)
        let positions = Self.outputPositions(path, motion)
        // The 60 px drift is kept: the picture ends well to the right of where it started.
        let travel = positions.last!.x - positions.first!.x
        XCTAssertGreaterThan(travel, 40)
        XCTAssertLessThan(travel, 80)
    }

    /// The case that broke the first version on real footage: the first frames of a chained estimate
    /// came back with scale about 0.3 and heavy shear (garbage). Locked shrugs it off, because a
    /// wildly zoomed-out frame warps to a huge quad that still covers the crop. Smooth, which keeps
    /// pose and so keeps the garbage, collapsed the crop. Capping each frame's move bounds the damage.
    func testFramesWithGarbageEstimatesDoNotCollapseSmoothsCrop() throws {
        var motion = Self.shakyDriftingMotion(frames: 60)
        let garbage = simd_float3x3(columns: (SIMD3<Float>(0.28, -0.11, 0), SIMD3<Float>(-0.07, 0.35, 0), SIMD3<Float>(590, 430, 0.99)))
        for i in 0..<20 {
            motion[i] = FrameMotion(index: i, transform: garbage * Self.translation(Double(i) * 3, 0))
        }
        let locked = try WarpToReferenceSolver().solve(motion: motion, frameSize: Self.frameSize)
        let capped = try SmoothedPathSolver().solve(motion: motion, frameSize: Self.frameSize)
        XCTAssertGreaterThan(capped.cropRetention, 0.5, "Smooth must keep a usable crop through garbage frames (kept \(capped.cropRetention), Locked \(locked.cropRetention))")

        // And no frame is moved by more than the caps, wherever the estimate says it should go.
        let solver = SmoothedPathSolver()
        let center = SIMD3<Float>(Float(Self.frameSize.width) / 2, Float(Self.frameSize.height) / 2, 1)
        for correction in capped.corrections {
            let moved = correction * center
            let shift = SIMD2<Double>(Double(moved.x / moved.z - center.x), Double(moved.y / moved.z - center.y))
            XCTAssertLessThanOrEqual(abs(shift.x), solver.maxShiftFraction * Double(Self.frameSize.width) + 0.01, "horizontal move")
            XCTAssertLessThanOrEqual(abs(shift.y), solver.maxShiftFraction * Double(Self.frameSize.height) + 0.01, "vertical move")
        }
    }

    func testTheCapsAreWhatKeepsSmoothSafe() throws {
        var motion = Self.shakyDriftingMotion(frames: 60)
        let garbage = simd_float3x3(columns: (SIMD3<Float>(0.28, -0.11, 0), SIMD3<Float>(-0.07, 0.35, 0), SIMD3<Float>(590, 430, 0.99)))
        for i in 0..<20 { motion[i] = FrameMotion(index: i, transform: garbage) }
        let capped = try SmoothedPathSolver().solve(motion: motion, frameSize: Self.frameSize)
        let uncapped = try? SmoothedPathSolver(maxShiftFraction: 100, maxRotation: 100, maxLogScale: 100).solve(motion: motion, frameSize: Self.frameSize)
        if let uncapped {
            XCTAssertGreaterThan(capped.cropRetention, uncapped.cropRetention, "without the caps the garbage frames are dragged and cost crop")
        } // else: uncapped found no common area at all, which makes the same point more strongly
    }

    func testClampedStopsAtTheLimitsAndLeavesSmallMovesAlone() {
        let big = SmoothedPathSolver.Pose(tx: 100, ty: -100, rotation: 1, logScale: -1)
        let capped = big.clamped(maxShift: SIMD2(10, 20), maxRotation: 0.1, maxLogScale: 0.2)
        XCTAssertEqual(capped.tx, 10); XCTAssertEqual(capped.ty, -20)
        XCTAssertEqual(capped.rotation, 0.1); XCTAssertEqual(capped.logScale, -0.2)
        let small = SmoothedPathSolver.Pose(tx: 3, ty: -2, rotation: 0.05, logScale: 0.1)
        let same = small.clamped(maxShift: SIMD2(10, 20), maxRotation: 0.1, maxLogScale: 0.2)
        XCTAssertEqual(same.tx, 3); XCTAssertEqual(same.ty, -2); XCTAssertEqual(same.rotation, 0.05); XCTAssertEqual(same.logScale, 0.1)
    }

    func testSmoothOfAStillCameraEqualsLocked() throws {
        let still = (0..<20).map { FrameMotion(index: $0, transform: matrix_identity_float3x3) }
        let smooth = try SmoothedPathSolver().solve(motion: still, frameSize: Self.frameSize)
        let locked = try WarpToReferenceSolver().solve(motion: still, frameSize: Self.frameSize)
        for (a, b) in zip(smooth.corrections, locked.corrections) {
            for column in 0..<3 { for row in 0..<3 { XCTAssertEqual(a[column][row], b[column][row], accuracy: 1e-5) } }
        }
        XCTAssertEqual(smooth.cropRetention, locked.cropRetention, accuracy: 1e-9)
    }

    func testPoseRoundTripsASimilarityAboutTheFrameCenter() {
        let center = SIMD2<Double>(480, 270)
        let angle = 0.05, scale = 1.04, tx = 12.0, ty = -7.0
        let c = cos(angle) * scale, s = sin(angle) * scale
        let original = SmoothedPathSolver.Pose(tx: tx, ty: ty, rotation: angle, logScale: log(scale))
        let matrix = original.matrix(aboutCenter: center)
        let read = SmoothedPathSolver.Pose(matrix, aboutCenter: center)
        XCTAssertEqual(read.tx, tx, accuracy: 1e-3)
        XCTAssertEqual(read.ty, ty, accuracy: 1e-3)
        XCTAssertEqual(read.rotation, angle, accuracy: 1e-5)
        XCTAssertEqual(read.logScale, log(scale), accuracy: 1e-5)
        XCTAssertEqual(Double(matrix[0][0]), c, accuracy: 1e-5)
        XCTAssertEqual(Double(matrix[0][1]), s, accuracy: 1e-5)
    }

    func testSmoothingTreatsTheEndsWithoutPullingTowardZero() {
        // A constant path stays constant, including at the ends.
        let poses = Array(repeating: SmoothedPathSolver.Pose(tx: 10, ty: -4, rotation: 0.1, logScale: 0.02), count: 30)
        for pose in SmoothedPathSolver.smooth(poses, sigma: 8) {
            XCTAssertEqual(pose.tx, 10, accuracy: 1e-9)
            XCTAssertEqual(pose.rotation, 0.1, accuracy: 1e-9)
        }
    }

    func testRotationIsUnwrappedBeforeSmoothing() {
        // Angles either side of +/-pi are the same direction; averaging them naively gives ~0.
        let poses = [3.1, -3.1, 3.1, -3.1, 3.1].map { SmoothedPathSolver.Pose(tx: 0, ty: 0, rotation: $0, logScale: 0) }
        let smoothed = SmoothedPathSolver.smooth(poses, sigma: 2)
        for pose in smoothed {
            XCTAssertGreaterThan(abs(pose.rotation), 2.5, "must stay near +/-pi, not collapse to zero: \(pose.rotation)")
        }
    }

    // MARK: - Through the pipeline

    /// Counts how many times motion is estimated.
    private final class CountingEstimator: MotionEstimator, @unchecked Sendable {
        private let inner = VisionRegistrationEstimator()
        private let lock = NSLock()
        private(set) var calls = 0
        func estimate(frame: CVPixelBuffer, reference: CVPixelBuffer) async throws -> FrameMotion {
            lock.withLock { calls += 1 }
            return try await inner.estimate(frame: frame, reference: reference)
        }
    }

    func testSwitchingModeDoesNotEstimateMotionAgain() async throws {
        let url = MotionEstimationTests.fixturesDirectory.appendingPathComponent("translate-shake.mov")
        let estimator = CountingEstimator()
        let first = try await ClipAnalyzer.analyze(movieURL: url, referenceIndex: 0, estimator: estimator, mode: .locked)
        let afterFirst = estimator.calls
        XCTAssertGreaterThan(afterFirst, 0)

        var crops: [StabilizationMode: Double] = [first.mode: first.path.cropRetention]
        for mode in [StabilizationMode.smooth, .off] {
            let again = try await ClipAnalyzer.analyze(movieURL: url, motion: first.motion, mode: mode)
            XCTAssertEqual(again.mode, mode)
            crops[mode] = again.path.cropRetention
        }
        XCTAssertEqual(estimator.calls, afterFirst, "changing mode must re-solve the path, not re-estimate the motion")
        XCTAssertEqual(crops[.off], 1)
        XCTAssertGreaterThanOrEqual(crops[.smooth]!, crops[.locked]!)
    }

    func testFailureSignalsAreJudgedForTheActiveMode() async throws {
        let url = MotionEstimationTests.fixturesDirectory.appendingPathComponent("translate-shake.mov")
        let motion = try await ClipAnalyzer.analyze(movieURL: url, referenceIndex: 0, estimator: VisionRegistrationEstimator(), mode: .off).motion
        // A residual meter that always reports a failing 5 px.
        let alwaysFive: (CameraPath) async throws -> Double? = { _ in 5.0 }

        let off = try await ClipAnalyzer.analyze(movieURL: url, motion: motion, mode: .off, residualMotion: alwaysFive)
        XCTAssertNil(off.measuredResidualMotion, "Off does not measure residual motion")
        XCTAssertFalse(off.assessment.reading(for: .cropRetention).failed)
        XCTAssertNil(off.assessment.reading(for: .residualMotion).value)
        XCTAssertFalse(off.assessment.failedSignals.contains(.residualMotion))

        let smooth = try await ClipAnalyzer.analyze(movieURL: url, motion: motion, mode: .smooth, residualMotion: alwaysFive)
        XCTAssertEqual(smooth.measuredResidualMotion, 5.0, "Smooth reports what it measured")
        XCTAssertNil(smooth.assessment.reading(for: .residualMotion).value, "but does not judge it: drift is kept on purpose")
        XCTAssertFalse(smooth.assessment.failedSignals.contains(.residualMotion))

        let locked = try await ClipAnalyzer.analyze(movieURL: url, motion: motion, mode: .locked, residualMotion: alwaysFive)
        XCTAssertEqual(locked.assessment.reading(for: .residualMotion).value, 5.0)
        XCTAssertTrue(locked.assessment.failedSignals.contains(.residualMotion), "Locked is judged on residual motion")
    }
}

/// A small seeded generator so the shaky test path is the same every run.
private struct SplitMix64Test {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double(z ^ (z >> 31)) / Double(UInt64.max)
    }
}
