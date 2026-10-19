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
    /// wildly zoomed-out frame warps to a huge quad that still covers the crop. A smoother that trusts
    /// the estimates dragged those frames far and collapsed the crop. The limit bounds the damage.
    func testFramesWithGarbageEstimatesDoNotCollapseSmoothsCrop() throws {
        var motion = Self.shakyDriftingMotion(frames: 60)
        let garbage = simd_float3x3(columns: (SIMD3<Float>(0.28, -0.11, 0), SIMD3<Float>(-0.07, 0.35, 0), SIMD3<Float>(590, 430, 0.99)))
        for i in 0..<20 {
            motion[i] = FrameMotion(index: i, transform: garbage * Self.translation(Double(i) * 3, 0))
        }
        let solver = SmoothedPathSolver()
        let path = try solver.solve(motion: motion, frameSize: Self.frameSize)
        XCTAssertGreaterThan(path.cropRetention, 0.5, "Smooth must keep a usable crop through garbage frames (kept \(path.cropRetention))")

        // And no corner of any frame moves by more than the limit, wherever the estimate says it should go.
        let w = Double(Self.frameSize.width), h = Double(Self.frameSize.height)
        let limit = solver.maxMoveFraction * (w * w + h * h).squareRoot()
        for correction in path.corrections {
            for corner in [SIMD2(0.0, 0.0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h)] {
                let p = correction * SIMD3<Float>(Float(corner.x), Float(corner.y), 1)
                let moved = simd_distance(SIMD2(Double(p.x / p.z), Double(p.y / p.z)), corner)
                XCTAssertLessThan(moved, limit + 0.01, "a corner moved \(moved) px; the limit is \(limit)")
            }
        }
    }

    func testTheLimitIsWhatKeepsSmoothSafe() throws {
        var motion = Self.shakyDriftingMotion(frames: 60)
        let garbage = simd_float3x3(columns: (SIMD3<Float>(0.28, -0.11, 0), SIMD3<Float>(-0.07, 0.35, 0), SIMD3<Float>(590, 430, 0.99)))
        for i in 0..<20 { motion[i] = FrameMotion(index: i, transform: garbage) }
        let limited = try SmoothedPathSolver().solve(motion: motion, frameSize: Self.frameSize)
        let unlimited = try? SmoothedPathSolver(maxMoveFraction: 1000).solve(motion: motion, frameSize: Self.frameSize)
        if let unlimited {
            XCTAssertGreaterThan(limited.cropRetention, unlimited.cropRetention, "without the limit the garbage frames are dragged and cost crop")
        } // else: unlimited found no common area at all, which makes the same point more strongly
    }

    func testSoftLimitApproachesTheLimitSmoothlyAndLeavesSmallMovesAlone() {
        let w = 960.0, h = 540.0
        let corners = [SIMD2(0.0, 0.0), SIMD2(w, 0), SIMD2(w, h), SIMD2(0, h)]
        func translated(_ x: Double) -> simd_double3x3 {
            simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(x, 0, 1)))
        }
        func shift(_ move: simd_double3x3) -> Double {
            let p = move * SIMD3<Double>(100, 100, 1)
            return p.x / p.z - 100
        }
        // A huge move comes out at, but never past, the limit, in the same direction.
        XCTAssertEqual(shift(SmoothedPathSolver.limiting(translated(5000), corners: corners, limit: 50)), 50, accuracy: 1e-6)
        XCTAssertEqual(shift(SmoothedPathSolver.limiting(translated(-5000), corners: corners, limit: 50)), -50, accuracy: 1e-6)
        // A move a tenth of the limit is changed by under one percent.
        XCTAssertEqual(shift(SmoothedPathSolver.limiting(translated(5), corners: corners, limit: 50)), 5, accuracy: 0.05)
        // It never jumps: a move just under the limit lands next to one just over it.
        let below = shift(SmoothedPathSolver.limiting(translated(49.9), corners: corners, limit: 50))
        let above = shift(SmoothedPathSolver.limiting(translated(50.1), corners: corners, limit: 50))
        XCTAssertEqual(below, above, accuracy: 0.5, "a hard clamp would have a corner here; this must be continuous")
        XCTAssertLessThan(above, 50)
        // The identity is untouched.
        XCTAssertEqual(SmoothedPathSolver.limiting(matrix_identity_double3x3, corners: corners, limit: 50), matrix_identity_double3x3)
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

    /// The reason Smooth filters the matrices instead of splitting them into parameters: a linear filter
    /// cannot add jitter at any point. Checked at five points on a clip with correlated shift, rotation
    /// and scale noise, which is what broke the parameter-by-parameter version.
    func testSmoothingNeverAddsJitterAtAnyPoint() throws {
        var rng = SplitMix64Test(seed: 7)
        // Rotation and shift jitter that cancel at one point of the frame (correlated, as estimator noise is).
        let motion: [FrameMotion] = (0..<60).map { i in
            let angle = (rng.unit() - 0.5) * 0.03
            let shift = -angle * 400 // the shift that keeps the point (400, 0) still
            let c = Float(cos(angle)), s = Float(sin(angle))
            let t = simd_float3x3(columns: (SIMD3<Float>(c, s, 0), SIMD3<Float>(-s, c, 0), SIMD3<Float>(Float(shift), 0, 1)))
            return FrameMotion(index: i, transform: t)
        }
        let off = try OriginalPathSolver().solve(motion: motion, frameSize: Self.frameSize)
        let smooth = try SmoothedPathSolver(maxMoveFraction: 1).solve(motion: motion, frameSize: Self.frameSize)
        for point in [SIMD2<Float>(400, 0), SIMD2(0, 0), SIMD2(960, 540), SIMD2(480, 270), SIMD2(100, 500)] {
            let before = Self.jitter2(Self.outputPositions(off, motion, point: point))
            let after = Self.jitter2(Self.outputPositions(smooth, motion, point: point))
            XCTAssertLessThanOrEqual(after, before + 1e-6, "Smooth added jitter at \(point): \(before) -> \(after)")
        }
    }

    /// Mean second difference of a path: the shake in it. Zero for a straight line.
    static func jitter2(_ positions: [SIMD2<Float>]) -> Double {
        var sum = 0.0
        for i in 1..<(positions.count - 1) {
            sum += Double(simd_distance(positions[i], (positions[i - 1] + positions[i + 1]) / 2))
        }
        return sum / Double(positions.count - 2)
    }

    func testSmoothingKeepsAConstantPathConstantIncludingAtTheEnds() {
        let poses = Array(repeating: SmoothedPathSolver.normalized(Self.translation(10, -4)), count: 30)
        for pose in SmoothedPathSolver.smooth(poses, sigma: 8) {
            XCTAssertEqual(pose[2][0], 10, accuracy: 1e-9)
            XCTAssertEqual(pose[2][1], -4, accuracy: 1e-9)
        }
    }

    // MARK: - The ends of the clip (#98)

    /// A pose with a uniform scale and a shift, as a matrix.
    static func pose(scale: Double, tx: Double, ty: Double = 0) -> simd_double3x3 {
        simd_double3x3(columns: (SIMD3(scale, 0, 0), SIMD3(0, scale, 0), SIMD3(tx, ty, 1)))
    }

    func testASteadyZoomAndPanIsNotBentAtEitherEndOfTheClip() {
        // Scale falling 1.29 to 0.89 and a pan of 400 px over 76 frames: a straight line in every entry.
        // Cutting the kernel off at the ends averaged the first and last frames from one side and lagged
        // them by about sigma frames of that trend, so the correction had to shrink whole frames.
        let poses = (0..<76).map { Self.pose(scale: 1.29 - 0.4 * Double($0) / 75, tx: -200 + 400 * Double($0) / 75) }
        let smoothed = SmoothedPathSolver.smooth(poses, sigma: 8)
        for (original, result) in zip(poses, smoothed) {
            for column in 0..<3 {
                for row in 0..<3 {
                    XCTAssertEqual(result[column][row], original[column][row], accuracy: 1e-9, "a straight-line path must come out unchanged, ends included")
                }
            }
        }
    }

    func testAConstantPathStaysConstant() {
        let poses = Array(repeating: Self.pose(scale: 1.1, tx: 12, ty: -7), count: 30)
        for result in SmoothedPathSolver.smooth(poses, sigma: 8) {
            XCTAssertEqual(result[0][0], 1.1, accuracy: 1e-12)
            XCTAssertEqual(result[2][0], 12, accuracy: 1e-12)
            XCTAssertEqual(result[2][2], 1, accuracy: 1e-12)
        }
    }

    func testAClipThatZoomsAndPansKeepsMostOfTheFrame() throws {
        // Steady zoom and pan with a little shake on top: the camera did something large and slow.
        var rng = SplitMix64Test(seed: 7)
        let motion = (0..<76).map { i -> FrameMotion in
            let t = Double(i) / 75
            let scale = 1.29 - 0.4 * t
            let shakeX = (rng.unit() - 0.5) * 6, shakeY = (rng.unit() - 0.5) * 6
            let m = simd_float3x3(columns: (
                SIMD3<Float>(Float(scale), 0, 0), SIMD3<Float>(0, Float(scale), 0),
                SIMD3<Float>(Float(-200 + 400 * t + shakeX), Float(shakeY), 1)
            ))
            return FrameMotion(index: i, transform: m)
        }
        let path = try SmoothedPathSolver().solve(motion: motion, frameSize: Self.frameSize)
        XCTAssertGreaterThan(path.cropRetention, 0.80, "smoothing a slow zoom and pan should not cost the frame")
        let locked = try WarpToReferenceSolver().solve(motion: motion, frameSize: Self.frameSize)
        XCTAssertGreaterThan(path.cropRetention, locked.cropRetention + 0.2, "and it keeps far more than Locked, which has to undo the zoom")
    }

    // MARK: - Where a clip starts (#98)

    func testALockedCropAboveTheWarningLineKeepsTheDefault() {
        XCTAssertEqual(ClipAnalyzer.recommendedMode(cropRetentions: [.off: 1, .smooth: 0.95, .locked: 0.80]), .locked)
        XCTAssertEqual(ClipAnalyzer.recommendedMode(cropRetentions: [.off: 1, .smooth: 0.95, .locked: 0.60]), .locked, "exactly at the line is fine")
    }

    func testAClipWhereLockedWouldKeepUnderSixtyPercentStartsInSmooth() {
        XCTAssertEqual(ClipAnalyzer.recommendedMode(cropRetentions: [.off: 1, .smooth: 0.93, .locked: 0.33]), .smooth)
        XCTAssertEqual(ClipAnalyzer.recommendedMode(cropRetentions: [.off: 1, .smooth: 0.93]), .smooth, "Locked could not be solved at all")
    }

    func testWhenNothingStabilizedKeepsEnoughTheClipStartsOff() {
        XCTAssertEqual(ClipAnalyzer.recommendedMode(cropRetentions: [.off: 1, .smooth: 0.5, .locked: 0.3]), .off)
        XCTAssertEqual(ClipAnalyzer.recommendedMode(cropRetentions: [:]), .off)
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

    /// The editor labels each choice with the crop it keeps, from one estimate (#88).
    func testCropRetentionsCoverEveryModeFromOneEstimate() async throws {
        let url = MotionEstimationTests.fixturesDirectory.appendingPathComponent("translate-shake.mov")
        let analysis = try await ClipAnalyzer.analyze(movieURL: url, referenceIndex: 0, estimator: VisionRegistrationEstimator(), mode: .locked)
        let crops = ClipAnalyzer.cropRetentions(motion: analysis.motion)

        XCTAssertEqual(Set(crops.keys), Set(StabilizationMode.allCases))
        XCTAssertEqual(crops[.off], 1, "Off keeps the whole frame")
        XCTAssertEqual(crops[.locked]!, analysis.path.cropRetention, accuracy: 1e-9, "the label must match what choosing Locked gives")
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
