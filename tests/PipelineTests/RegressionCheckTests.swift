import XCTest
@testable import StillMotionsPipeline

final class RegressionCheckTests: XCTestCase {
    /// Five clips that all pass comfortably.
    static let good: [String: ClipMetrics] = [
        "a": ClipMetrics(cropRetention: 0.95, residualMotion: 0.20, loopSeamRatio: 1.0),
        "b": ClipMetrics(cropRetention: 0.90, residualMotion: 0.30, loopSeamRatio: 1.1),
        "c": ClipMetrics(cropRetention: 0.85, residualMotion: 0.25, loopSeamRatio: 0.9),
        "d": ClipMetrics(cropRetention: 0.80, residualMotion: 0.40, loopSeamRatio: 1.2),
        "e": ClipMetrics(cropRetention: 0.75, residualMotion: 0.35, loopSeamRatio: 1.0),
    ]

    var baseline: Baseline { Baseline(clips: Self.good, estimator: "registration", solver: "warp") }

    func testIdenticalRunIsNotARegression() {
        XCTAssertEqual(RegressionCheck.compare(baseline: baseline, current: Self.good), [])
    }

    func testImprovementIsNotARegression() {
        var better = Self.good
        for key in better.keys { better[key]!.cropRetention += 0.02; better[key]!.residualMotion! *= 0.5 }
        XCTAssertEqual(RegressionCheck.compare(baseline: baseline, current: better), [])
    }

    // MARK: - Clause 1: median crop retention

    func testMedianCropRetentionDropOfMoreThanTwoPointsFails() {
        var worse = Self.good
        for key in worse.keys { worse[key]!.cropRetention -= 0.03 } // median 0.85 -> 0.82
        let problems = RegressionCheck.compare(baseline: baseline, current: worse)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("crop retention"), "\(problems)")
    }

    func testMedianCropRetentionDropOfTwoPointsOrLessPasses() {
        var slightly = Self.good
        for key in slightly.keys { slightly[key]!.cropRetention -= 0.02 }
        XCTAssertEqual(RegressionCheck.compare(baseline: baseline, current: slightly), [])
    }

    // MARK: - Clause 2: median residual motion

    func testMedianResidualMotionRiseOfMoreThanTenPercentFails() {
        var worse = Self.good
        for key in worse.keys { worse[key]!.residualMotion! *= 1.15 } // stays under 1 px: clause 3 does not fire
        let problems = RegressionCheck.compare(baseline: baseline, current: worse)
        XCTAssertEqual(problems.count, 1)
        XCTAssertTrue(problems[0].contains("residual motion"), "\(problems)")
    }

    func testMedianResidualMotionRiseOfTenPercentOrLessPasses() {
        var slightly = Self.good
        for key in slightly.keys { slightly[key]!.residualMotion! *= 1.09 }
        XCTAssertEqual(RegressionCheck.compare(baseline: baseline, current: slightly), [])
    }

    // MARK: - Clause 3: a clip that used to pass now fails

    func testOneClipFailingIsCaughtEvenWhenTheMediansBarelyMove() {
        // The point of the per-clip clause: four clips unchanged, one goes badly wrong. The
        // medians do not move at all, so only this clause can see it.
        var current = Self.good
        current["a"] = ClipMetrics(cropRetention: 0.95, residualMotion: 0.20, loopSeamRatio: 4.0)
        let problems = RegressionCheck.compare(baseline: baseline, current: current)
        XCTAssertEqual(problems.count, 1, "\(problems)")
        XCTAssertTrue(problems[0].contains("'a'") && problems[0].contains("loopSeam"), "\(problems)")
    }

    func testEachThresholdTripsTheClipClause() {
        let cases: [(ClipMetrics, FailureSignal)] = [
            (ClipMetrics(cropRetention: 0.59, residualMotion: 0.2, loopSeamRatio: 1.0), .cropRetention),
            (ClipMetrics(cropRetention: 0.9, residualMotion: 1.0, loopSeamRatio: 1.0), .residualMotion),
            (ClipMetrics(cropRetention: 0.9, residualMotion: 0.2, loopSeamRatio: 1.51), .loopSeam),
        ]
        for (metrics, signal) in cases {
            XCTAssertEqual(metrics.failures, [signal])
            var current = Self.good
            current["c"] = metrics
            let problems = RegressionCheck.compare(baseline: baseline, current: current)
            XCTAssertTrue(problems.contains { $0.contains("'c'") && $0.contains(signal.rawValue) }, "\(signal): \(problems)")
        }
    }

    func testAClipThatAlreadyFailedInTheBaselineIsNotReportedAgain() {
        var base = Self.good
        base["e"] = ClipMetrics(cropRetention: 0.50, residualMotion: 0.3, loopSeamRatio: 1.0) // failed already
        var current = base
        current["e"]!.cropRetention = 0.49 // still failing, slightly worse; medians unaffected
        let problems = RegressionCheck.compare(baseline: Baseline(clips: base, estimator: "r", solver: "w"), current: current)
        XCTAssertEqual(problems, [])
    }

    // MARK: - Other behaviour

    func testAMissingClipFails() {
        var current = Self.good
        current["d"] = nil
        let problems = RegressionCheck.compare(baseline: baseline, current: current)
        XCTAssertTrue(problems.contains { $0.contains("'d'") && $0.contains("not produced") }, "\(problems)")
    }

    func testANewClipDoesNotMoveTheMedians() {
        var current = Self.good
        current["new"] = ClipMetrics(cropRetention: 0.61, residualMotion: 0.9, loopSeamRatio: 1.4)
        XCTAssertEqual(RegressionCheck.compare(baseline: baseline, current: current), [])
    }

    func testUnmeasuredSignalsAreNotFailures() {
        XCTAssertTrue(ClipMetrics(cropRetention: 0.9).passed)
        XCTAssertEqual(ClipMetrics(cropRetention: 0.5).failures, [.cropRetention])
    }

    func testBaselineRoundTripsThroughJSON() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baseline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try baseline.write(to: url)
        XCTAssertEqual(try Baseline.load(from: url), baseline)
    }

    func testMedian() {
        XCTAssertEqual(RegressionCheck.median([3, 1, 2]), 2)
        XCTAssertEqual(RegressionCheck.median([4, 1, 3, 2]), 2.5)
        XCTAssertEqual(RegressionCheck.median([]), 0)
    }
}
