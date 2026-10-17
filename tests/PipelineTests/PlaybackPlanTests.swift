import XCTest
@testable import StillMotionsPipeline

final class PlaybackPlanTests: XCTestCase {
    /// 90 frames at 30 fps, evenly spaced.
    static let evenTimes = (0..<90).map { Double($0) / 30.0 }

    static func loop(start: Int = 20, returnIndex: Int = 70) -> LoopSelection {
        // A loop with the 3-frame crossfade the selector produces.
        var frames: [LoopFrameRecipe] = []
        for offset in 0..<(returnIndex - start) {
            if offset < 3 {
                frames.append(LoopFrameRecipe(primary: returnIndex + offset, secondary: start + offset, secondaryWeight: Float(offset + 1) / 4))
            } else {
                frames.append(LoopFrameRecipe(primary: start + offset, secondary: nil, secondaryWeight: 0))
            }
        }
        return LoopSelection(
            startIndex: start, returnIndex: returnIndex, frames: frames,
            seamRatioBeforeCrossfade: 8, seamRatio: 2, medianStep: 0.01
        )
    }

    func testOncePlaysEveryDecimatedFrameInOrder() {
        let plan = PlaybackPlan.make(mode: .once, frameTimes: Self.evenTimes, loop: nil, frameRate: .fps20)
        XCTAssertEqual(plan.steps.count, 60, "3 s at 20 fps")
        XCTAssertEqual(plan.steps.map(\.primary), plan.steps.map(\.primary).sorted())
        XCTAssertTrue(plan.steps.allSatisfy { $0.secondary == nil })
        XCTAssertEqual(plan.stepDuration, 0.05, accuracy: 1e-12)
        XCTAssertEqual(plan.duration, 3.0, accuracy: 1e-9)
    }

    func testBounceIsTwoNMinusOneAndPalindromic() {
        let once = PlaybackPlan.make(mode: .once, frameTimes: Self.evenTimes, loop: nil, frameRate: .fps20)
        let bounce = PlaybackPlan.make(mode: .bounce, frameTimes: Self.evenTimes, loop: nil, frameRate: .fps20)
        XCTAssertEqual(bounce.steps.count, 2 * once.steps.count - 1)
        XCTAssertEqual(bounce.steps.map(\.primary), bounce.steps.map(\.primary).reversed(), "a bounce reads the same both ways")
        XCTAssertEqual(bounce.steps.first, bounce.steps.last)
    }

    func testLoopUsesTheSelectedLoopWithItsCrossfade() {
        let loop = Self.loop()
        let plan = PlaybackPlan.make(mode: .loop, frameTimes: Self.evenTimes, loop: loop, frameRate: .fps25)
        // 50 loop frames at 30 fps is 1.667 s; at 25 fps that is 41 steps.
        XCTAssertEqual(plan.steps.count, 41)
        XCTAssertEqual(plan.steps.first?.secondary, 20, "the loop opens on the crossfade")
        XCTAssertNotNil(plan.steps[0].secondary)
        XCTAssertTrue(plan.steps.dropFirst(5).allSatisfy { $0.secondary == nil }, "the crossfade is only at the start")
        XCTAssertTrue(plan.steps.allSatisfy { ($0.primary >= 20 && $0.primary < 70) || $0.primary >= 70 }, "frames come from the loop and its continuation")
    }

    func testLoopNeverRepeatsAFrameAtTheSeam() {
        // The loop excludes its return frame, so the jump from the last step to the first is not
        // the same picture twice (a visible hitch).
        let plan = PlaybackPlan.make(mode: .loop, frameTimes: Self.evenTimes, loop: Self.loop(), frameRate: .fps20)
        let last = plan.steps.last!, first = plan.steps.first!
        XCTAssertNotEqual(last.primary, first.primary)
        XCTAssertNotEqual(last.primary, first.secondary)
    }

    func testLoopModeWithNoLoopFoundPlaysTheWholeClip() {
        let plan = PlaybackPlan.make(mode: .loop, frameTimes: Self.evenTimes, loop: nil, frameRate: .fps20)
        XCTAssertEqual(plan, PlaybackPlan.make(mode: .once, frameTimes: Self.evenTimes, loop: nil, frameRate: .fps20))
    }

    func testFrameRateDecimatesWithoutTouchingTheOrder() {
        let counts = GifFrameRate.allCases.map { PlaybackPlan.make(mode: .once, frameTimes: Self.evenTimes, loop: nil, frameRate: $0).steps.count }
        XCTAssertEqual(counts, [50, 60, 75], "16.67, 20 and 25 fps over 3 s")
    }

    func testAVariableFrameRateClipPlaysForAsLongAsItDoes() {
        // 30 fps for a second, a slow stretch at 10 fps for a second, then 30 fps again: 2.0 s of
        // 20 + 10 + 30 frames. Index-based decimation would play this at the wrong length.
        var times: [Double] = (0..<30).map { Double($0) / 30 }
        times += (0..<10).map { 1.0 + Double($0) / 10 }
        times += (0..<30).map { 2.0 + Double($0) / 30 }
        let plan = PlaybackPlan.make(mode: .once, frameTimes: times, loop: nil, frameRate: .fps20)
        XCTAssertEqual(plan.duration, 3.0, accuracy: 0.06, "the clip is 3 s long, and the preview should be too")
    }

    func testSteppingThroughTimeRepeatsForever() {
        let plan = PlaybackPlan.make(mode: .once, frameTimes: Self.evenTimes, loop: nil, frameRate: .fps20)
        XCTAssertEqual(plan.step(atElapsed: 0), plan.steps[0])
        XCTAssertEqual(plan.step(atElapsed: 0.05), plan.steps[1])
        XCTAssertEqual(plan.step(atElapsed: 0.0499), plan.steps[0])
        XCTAssertEqual(plan.step(atElapsed: plan.duration), plan.steps[0], "Once still repeats in the preview")
        XCTAssertEqual(plan.step(atElapsed: plan.duration + 0.05), plan.steps[1])
        XCTAssertEqual(plan.step(atElapsed: -3), plan.steps[0])
        XCTAssertNil(PlaybackPlan(steps: [], frameRate: .fps20).step(atElapsed: 1))
    }

    func testPlansAreCheapToRebuildSoSwitchingIsInstant() {
        // Re-planning is just index arithmetic over a clip's frame times. A hundred switches
        // between every mode and rate must take a tiny fraction of a second.
        let start = ContinuousClock.now
        for _ in 0..<100 {
            for mode in PlaybackMode.allCases {
                for rate in GifFrameRate.allCases {
                    _ = PlaybackPlan.make(mode: mode, frameTimes: Self.evenTimes, loop: Self.loop(), frameRate: rate)
                }
            }
        }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(500), "900 plans took \(elapsed)")
    }

    // MARK: - Preview equals export

    func testThePreviewHasExactlyTheFramesAnExportWouldProduce() async throws {
        // For each mode, the number of steps in the plan equals the frame count of a real GIF export
        // of the same clip, mode and rate. The preview is only honest if this holds.
        let fixture = "translate-shake"
        let (motion, size) = try CameraPathTests.motion(fixture: fixture)
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
        let movie = CameraPathTests.fixturesDirectory.appendingPathComponent("\(fixture).mov")
        let (signatures, frameRate) = try await LoopSelectionTests.signatures(fixture: fixture, stabilized: true)
        guard case .selected(let loop) = try LoopSelector.select(signatures: signatures, frameRate: frameRate, mode: .loop) else {
            return XCTFail("no loop selected")
        }
        let times = Self.evenTimes

        for mode in PlaybackMode.allCases {
            for rate in GifFrameRate.allCases {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).gif")
                defer { try? FileManager.default.removeItem(at: url) }
                let exported = try await ClipExporter.exportGIF(
                    movieURL: movie, path: path, preset: .small, frameRate: rate, mode: mode,
                    loop: mode == .loop ? loop : nil, to: url
                )
                let plan = PlaybackPlan.make(mode: mode, frameTimes: times, loop: loop, frameRate: rate)
                XCTAssertEqual(plan.steps.count, exported.frameCount, "\(mode) at \(rate): the preview and the export disagree")
            }
        }
    }
}
