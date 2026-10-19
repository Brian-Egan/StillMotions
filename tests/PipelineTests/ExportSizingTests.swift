import XCTest
import simd
@testable import StillMotionsPipeline

/// #32: the rules and arithmetic behind the export screen.
final class ExportSizingTests: XCTestCase {
    // MARK: - The format matrix

    func testLoopCannotBeExportedAsMp4ButEverythingElseCan() {
        for mode in PlaybackMode.allCases {
            for format in ExportFormat.allCases {
                let expected = !(mode == .loop && format == .mp4)
                XCTAssertEqual(ExportMatrix.isAllowed(format: format, mode: mode), expected, "\(mode) as \(format)")
                XCTAssertEqual(ExportMatrix.reason(format: format, mode: mode) == nil, expected, "\(mode) as \(format): a reason exactly when it is refused")
            }
        }
    }

    func testTheReasonIsOneReadableLine() throws {
        let reason = try XCTUnwrap(ExportMatrix.reason(format: .mp4, mode: .loop))
        XCTAssertFalse(reason.contains("\n"))
        XCTAssertTrue(reason.contains("GIF"), "it should point at what to use instead: \(reason)")
    }

    func testChoosingLoopWhileMp4IsSelectedSwitchesToGif() {
        XCTAssertEqual(ExportMatrix.format(.mp4, afterSelecting: .loop), .gif)
        XCTAssertEqual(ExportMatrix.format(.mp4, afterSelecting: .bounce), .mp4)
        XCTAssertEqual(ExportMatrix.format(.mp4, afterSelecting: .once), .mp4)
        XCTAssertEqual(ExportMatrix.format(.gif, afterSelecting: .loop), .gif)
    }

    // MARK: - Frame counts and sizes

    static let frameTimes = (0..<90).map { Double($0) / 30 }   // 3 s at 30 fps
    static var path: CameraPath { CameraPath(
        corrections: Array(repeating: matrix_identity_float3x3, count: 90),
        crop: CGRect(x: 0, y: 0, width: 1440, height: 1080), cropRetention: 0.8
    ) }

    func testMp4FrameCountsAreTheSourceFramesAndBounceTurnsOnce() {
        func count(_ mode: PlaybackMode) -> Int {
            ExportSizing.frameCount(format: .mp4, mode: mode, gifRate: .fps20, frameTimes: Self.frameTimes, loop: nil)
        }
        XCTAssertEqual(count(.once), 90)
        XCTAssertEqual(count(.bounce), 179)
    }

    func testGifFrameCountsFollowTheRate() {
        func count(_ rate: GifFrameRate) -> Int {
            ExportSizing.frameCount(format: .gif, mode: .once, gifRate: rate, frameTimes: Self.frameTimes, loop: nil)
        }
        XCTAssertEqual(count(.fps20), 60)
        XCTAssertEqual(count(.fps25), 75)
        XCTAssertEqual(count(.fps16_67), 50)
    }

    func testEstimatesRiseWithThePresetForBothFormats() {
        for format in ExportFormat.allCases {
            let sizes = SizePreset.allCases.map { preset in
                ExportSizing.estimate(
                    format: format, preset: preset, mode: .once, gifRate: .fps20, path: Self.path,
                    frameTimes: Self.frameTimes, loop: nil, sourceFrameRate: 30, content: nil
                )
            }
            XCTAssertLessThan(sizes[0], sizes[1], "\(format): small < medium")
            XCTAssertLessThan(sizes[1], sizes[2], "\(format): medium < full")
        }
    }

    func testTheOutputSizeIsTheExportersSize() {
        // The estimate must be for the dimensions the exporter will actually write.
        for preset in SizePreset.allCases {
            let input = ExportSizing.input(
                format: .gif, preset: preset, mode: .once, gifRate: .fps20, path: Self.path,
                frameTimes: Self.frameTimes, loop: nil, sourceFrameRate: 30, content: nil
            )
            let expected = OutputSize.size(forCrop: Self.path.crop, longEdge: preset.longEdge)
            XCTAssertEqual(CGFloat(input.width), expected.width)
            XCTAssertEqual(CGFloat(input.height), expected.height)
        }
    }

    func testMoreFramesAtAHigherRateCostMoreBytes() {
        func gif(_ rate: GifFrameRate) -> Int {
            ExportSizing.estimate(
                format: .gif, preset: .medium, mode: .once, gifRate: rate, path: Self.path,
                frameTimes: Self.frameTimes, loop: nil, sourceFrameRate: 30, content: nil
            )
        }
        XCTAssertLessThan(gif(.fps16_67), gif(.fps20))
        XCTAssertLessThan(gif(.fps20), gif(.fps25))
    }
}
