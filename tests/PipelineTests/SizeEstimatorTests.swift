import XCTest
@testable import PipelineCore

/// #31: the pre-export size estimate. The coefficients are fitted from real exports by
/// `stillmotions-harness estimate-accuracy`, and its accuracy is judged there; these tests pin the
/// arithmetic, with hand-built models so they do not move when the coefficients are refitted.
final class SizeEstimatorTests: XCTestCase {
    static let content = ContentFeatures(detail: 4, edgeDensity: 0.15, change: 1.5, changeFraction: 0.2, colorEntropy: 7)

    /// A GIF model with one fixed bytes-per-pixel-frame and no other terms.
    static func flatGif(bytesPerPixelFrame: Double) -> SizeModel {
        SizeModel(gifIntercept: log(bytesPerPixelFrame), gifWeights: [:], typicalContent: content, mp4FractionOfTarget: 1)
    }

    static func gif(_ frames: Int = 60, width: Int = 720, height: Int = 404, content: ContentFeatures? = nil) -> SizeInput {
        SizeInput(format: .gif, width: width, height: height, frameCount: frames, gifRate: .fps20, sourceFrameRate: 30, cropRetention: 0.8, content: content)
    }

    func testMp4IsTheEncodersBitrateTargetOverTheClipsDuration() {
        // 720x406 at 30 fps: 0.08 bits/pixel/frame is 701,568 bit/s; 90 frames is 3 s.
        let estimate = SizeEstimator(model: Self.flatGif(bytesPerPixelFrame: 1)).estimate(
            SizeInput(format: .mp4, width: 720, height: 406, frameCount: 90, sourceFrameRate: 30, cropRetention: 1)
        )
        XCTAssertEqual(estimate, 263_088)
    }

    func testMp4NeverFallsBelowTheEncodersMinimumBitRate() {
        // 64x48 at 30 fps would be 7,373 bit/s; the encoder floors it at 300,000. 30 frames is 1 s.
        let estimate = SizeEstimator().estimate(SizeInput(format: .mp4, width: 64, height: 48, frameCount: 30, sourceFrameRate: 30, cropRetention: 1))
        XCTAssertEqual(estimate, 37_500)
    }

    func testMp4ScalesWithTheFittedFraction() {
        var model = Self.flatGif(bytesPerPixelFrame: 1)
        model.mp4FractionOfTarget = 0.5
        let input = SizeInput(format: .mp4, width: 720, height: 406, frameCount: 90, sourceFrameRate: 30, cropRetention: 1)
        XCTAssertEqual(SizeEstimator(model: model).estimate(input), 131_544)
    }

    func testGifIsPixelsTimesFramesTimesTheCoefficient() {
        let estimator = SizeEstimator(model: Self.flatGif(bytesPerPixelFrame: 0.25))
        XCTAssertEqual(estimator.estimate(Self.gif(60)), Int((720.0 * 404 * 60 * 0.25).rounded()))
        XCTAssertEqual(estimator.estimate(Self.gif(120)), 2 * estimator.estimate(Self.gif(60)), "twice the frames, twice the bytes")
        XCTAssertEqual(estimator.estimate(Self.gif(60, width: 360, height: 202)), estimator.estimate(Self.gif(60)) / 4, accuracy: 1, "a quarter of the pixels, a quarter of the bytes")
    }

    func testATermsWeightIsAppliedToItsValue() {
        // Weight 1 on ln(detail + 0.05): the estimate is multiplied by (detail + 0.05).
        var model = Self.flatGif(bytesPerPixelFrame: 0.1)
        model.gifWeights = [.logDetail: 1]
        let estimator = SizeEstimator(model: model)
        var busy = Self.content; busy.detail = 9.95
        var plain = Self.content; plain.detail = 0.95
        let ratio = Double(estimator.estimate(Self.gif(content: busy))) / Double(estimator.estimate(Self.gif(content: plain)))
        XCTAssertEqual(ratio, 10, accuracy: 0.01)
    }

    func testEveryTermHasAFiniteValueForAnyReasonableClip() {
        let model = Self.flatGif(bytesPerPixelFrame: 0.25)
        let edge = SizeInput(
            format: .gif, width: 2, height: 2, frameCount: 1, sourceFrameRate: 0, cropRetention: 0,
            content: ContentFeatures(detail: 0, edgeDensity: 0, change: 0, changeFraction: 0, colorEntropy: 0)
        )
        for term in SizeTerm.allCases {
            XCTAssertTrue(model.value(of: term, for: edge).isFinite, "\(term) is not finite for a degenerate clip")
        }
    }

    func testWithoutMeasuredContentTheEstimateAssumesATypicalClip() {
        var model = Self.flatGif(bytesPerPixelFrame: 0.2)
        model.gifWeights = [.logDetail: 0.3, .logEdgeDensity: 0.2, .colorEntropy: 0.05]
        let estimator = SizeEstimator(model: model)
        XCTAssertEqual(estimator.estimate(Self.gif(content: nil)), estimator.estimate(Self.gif(content: model.typicalContent)))
    }

    func testNothingToEncodeIsZeroBytes() {
        let estimator = SizeEstimator(model: Self.flatGif(bytesPerPixelFrame: 0.25))
        XCTAssertEqual(estimator.estimate(Self.gif(0)), 0)
        XCTAssertEqual(estimator.estimate(Self.gif(60, width: 0, height: 0)), 0)
    }

    func testTheEstimateOrdersSmallMediumFullForEveryFormat() {
        // The estimate exists to support this choice, so the order must hold (PRD R-13).
        let estimator = SizeEstimator()
        for format in ExportFormat.allCases {
            let sizes = [(480, 270), (720, 404), (1920, 1080)].map { w, h in
                estimator.estimate(SizeInput(format: format, width: w, height: h, frameCount: 60, sourceFrameRate: 30, cropRetention: 0.8, content: Self.content))
            }
            XCTAssertLessThan(sizes[0], sizes[1], "\(format): small should be smaller than medium")
            XCTAssertLessThan(sizes[1], sizes[2], "\(format): medium should be smaller than full")
        }
    }

    func testAModelSurvivesBeingSavedAndLoaded() throws {
        var model = Self.flatGif(bytesPerPixelFrame: 0.3)
        model.gifWeights = [.logDetail: 0.31, .bounce: -0.1, .logCropRetention: 0.2]
        let decoded = try JSONDecoder().decode(SizeModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(decoded, model)
    }

    func testEstimatingIsFastEnoughToRunOnEveryTap() {
        let estimator = SizeEstimator()
        let input = Self.gif(60, content: Self.content)
        let start = ContinuousClock.now
        var total = 0
        for _ in 0..<10_000 { total &+= estimator.estimate(input) }
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(200), "10,000 estimates took \(elapsed) (\(total))")
    }
}
