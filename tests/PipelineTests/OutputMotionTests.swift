import XCTest
import simd
@testable import HarnessCLI

/// #98: the harness's way of measuring how much a clip's picture moves, from its frames. It is what
/// compares our output with another app's GIF, so it has to be right about a known motion.
final class OutputMotionTests: XCTestCase {
    static let side = OutputMotion.width

    /// A fixed, textured picture (smooth blobs and edges), shifted by whole pixels with wrap-around.
    static func picture(shiftX: Int, shiftY: Int) -> [Float] {
        var out = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let sx = ((x - shiftX) % side + side) % side, sy = ((y - shiftY) % side + side) % side
                let a = sin(Float(sx) * 0.11) * cos(Float(sy) * 0.07)
                let b = sin(Float(sx + 2 * sy) * 0.05)
                let edge: Float = ((sx / 23) + (sy / 31)) % 2 == 0 ? 0.6 : -0.6
                out[y * side + x] = 128 + 60 * (a + b) + 40 * edge
            }
        }
        return out
    }

    func testAKnownShiftIsRecovered() {
        let correlator = PhaseCorrelator()
        let base = correlator.spectrum(of: Self.picture(shiftX: 0, shiftY: 0))
        for (dx, dy) in [(3, 0), (0, -5), (7, 4), (-12, 9)] {
            let moved = correlator.spectrum(of: Self.picture(shiftX: dx, shiftY: dy))
            let found = correlator.shift(of: moved, relativeTo: base)
            XCTAssertEqual(found.x, Double(dx), accuracy: 0.15, "x shift \(dx),\(dy)")
            XCTAssertEqual(found.y, Double(dy), accuracy: 0.15, "y shift \(dx),\(dy)")
        }
    }

    func testASteadyPanHasNoJitterButARealPath() {
        // 2 px a frame to the right for 40 frames: a pan, not shake.
        let frames = (0..<40).map { Self.picture(shiftX: 2 * $0, shiftY: 0) }
        let result = OutputMotion.measure(frames: frames, times: (0..<40).map { Double($0) / 30 })
        XCTAssertLessThan(result.jitter, 0.2, "a steady pan is slow movement, not shake")
        // The path is in 180x240 units, so 78 px of 256-wide shift is about 55 of them.
        XCTAssertEqual(result.xRange, 78 * OutputMotion.unitsX, accuracy: 3)
        XCTAssertEqual(result.netPan, result.xRange, accuracy: 3)
        XCTAssertLessThan(result.stepMax, 2.5)
    }

    func testShakeOnTopOfAPanIsMeasuredAsJitter() {
        // The same pan with the picture bouncing 3 px left and right every other frame.
        let frames = (0..<40).map { Self.picture(shiftX: 2 * $0 + ($0 % 2 == 0 ? 3 : -3), shiftY: 0) }
        let shaky = OutputMotion.measure(frames: frames, times: (0..<40).map { Double($0) / 30 })
        let steady = OutputMotion.measure(frames: (0..<40).map { Self.picture(shiftX: 2 * $0, shiftY: 0) }, times: (0..<40).map { Double($0) / 30 })
        XCTAssertGreaterThan(shaky.jitter, steady.jitter + 1.5)
    }

    func testJitterIsMeasuredOverTimeNotOverFrames() {
        // The same real motion sampled at 30 fps and at 15 fps must give the same jitter: a window of
        // frames would be twice as long in time at 15 fps and read the shake as slow movement.
        func path(rate: Double, count: Int) -> ([SIMD2<Double>], [Double]) {
            let times = (0..<count).map { Double($0) / rate }
            return (times.map { SIMD2(20 * sin(2 * .pi * 2.0 * $0) + 30 * $0, 0) }, times)   // 2 Hz shake on a pan
        }
        let (fastPath, fastTimes) = path(rate: 30, count: 90)
        let (slowPath, slowTimes) = path(rate: 15, count: 45)
        let fast = OutputMotion.summarize(fastPath, times: fastTimes).jitter
        let slow = OutputMotion.summarize(slowPath, times: slowTimes).jitter
        XCTAssertEqual(slow, fast, accuracy: fast * 0.15, "30 fps gave \(fast), 15 fps gave \(slow)")
    }

    func testRejectedFramesAreGroupedByTheRuleThatRejectedThem() {
        let reasons = [
            "frame 3: estimated transform rejected as implausible: scale 1.31 outside 0.8...1.25",
            "frame 4: estimated transform rejected as implausible: scale 0.62 outside 0.8...1.25",
            "frame 9: estimated transform rejected as implausible: rotation 0.2 rad exceeds ±0.14",
            "frame 12: estimated transform rejected as implausible: translation 400px exceeds 0.25 of frame diagonal",
            "frame 15: registration request returned nothing",
        ]
        XCTAssertEqual(EstimationFailures.classify(reasons), ["scale": 2, "rotation": 1, "translation": 1, "estimator found nothing": 1])
        XCTAssertEqual(EstimationFailures.classify([]), [:])
    }
}

/// #102: what a "show the original when stabilizing made it shakier" rule would do, computed from the study rows.
final class GuardSummaryTests: XCTestCase {
    private func row(off: Double, smooth: Double) -> PolicyStudy.Row {
        let none = PolicyStudy.Outcome(cropKept: 1, jitter: nil, netPan: nil)
        return PolicyStudy.Row(
            clip: "c", personCoverage: 0, frames: 60, off: PolicyStudy.Outcome(cropKept: 1, jitter: off, netPan: 0),
            unmasked: ["smooth-12": PolicyStudy.Outcome(cropKept: 0.9, jitter: smooth, netPan: 0)], masked: ["smooth-12": none],
            estimateSecondsUnmasked: 1, estimateSecondsMasked: 0, estimationFailuresUnmasked: 0, estimationFailuresMasked: 0
        )
    }

    func testTheGuardRemovesAnyClipThatGotWorseAndChangesNothingElse() {
        let summary = PolicyStudy.guardSummary([row(off: 1.0, smooth: 0.4), row(off: 0.5, smooth: 0.8), row(off: 0.3, smooth: 0.6), row(off: 0.8, smooth: 0.2)])
        XCTAssertEqual(summary.clips, 4)
        XCTAssertEqual(summary.smoothWorseThanOff, 2)
        XCTAssertEqual(summary.smoothMoreThanFifteenPercentWorse, 2)
        XCTAssertEqual(summary.worstRatioToday, 2.0, accuracy: 1e-9)
        XCTAssertEqual(summary.worstRatioWithGuard, 1.0, accuracy: 1e-9, "never worse than the original")
        // The two clips that were helped keep their gain (0.4 and 0.25 of Off), the other two become 1.0.
        XCTAssertEqual(summary.medianRatioWithGuard, 1.0, accuracy: 1e-9)
    }

    func testClipsWithNothingToMeasureAreLeftOut() {
        XCTAssertEqual(PolicyStudy.guardSummary([row(off: 0.01, smooth: 0.5)]).clips, 0)
        XCTAssertEqual(PolicyStudy.guardSummary([]).clips, 0)
    }
}
