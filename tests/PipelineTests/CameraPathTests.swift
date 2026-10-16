import XCTest
import simd
@testable import StillMotionsPipeline

final class CameraPathTests: XCTestCase {
    static let fixturesDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/synthetic", isDirectory: true)
    }()

    static let allFixtures = [
        "translate-linear", "translate-shake", "rotate", "scale", "combined",
        "periodic", "moving-subject", "parallax",
    ]

    let frameSize = CGSize(width: 1920, height: 1080)

    // MARK: - Helpers

    /// A fixture's sidecar truth as solver input, expressed relative to `referenceIndex`
    /// (not necessarily the sidecar's own reference), the way an estimator reports it.
    static func motion(fixture: String, referenceIndex: Int? = nil) throws -> (motion: [FrameMotion], size: CGSize) {
        let truth = try FixtureTruth.load(from: fixturesDirectory.appendingPathComponent("\(fixture).truth.json"))
        let reference = referenceIndex ?? truth.referenceFrameIndex
        let referenceInverse = truth.frames[reference].matrix.inverse
        let motion = truth.frames.map {
            FrameMotion(index: $0.index, transform: $0.matrix * referenceInverse)
        }
        return (motion, CGSize(width: truth.width, height: truth.height))
    }

    /// A cropped, stabilized output pixel at `corner` samples frame `motion` at
    /// `transform * corner`. It is opaque (not a black edge) iff that lands inside the frame.
    func assertCropCornersInsideEveryFrame(
        _ path: CameraPath, motion: [FrameMotion], size: CGSize,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let crop = path.crop
        let corners = [
            CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
            CGPoint(x: crop.maxX, y: crop.maxY), CGPoint(x: crop.minX, y: crop.maxY),
        ]
        let slack: Float = 0.01 // Float rounding in the inverse; far below a pixel
        for frame in motion {
            for corner in corners {
                let p = frame.transform * SIMD3<Float>(Float(corner.x), Float(corner.y), 1)
                let x = p.x / p.z, y = p.y / p.z
                XCTAssertTrue(
                    x >= -slack && x <= Float(size.width) + slack && y >= -slack && y <= Float(size.height) + slack,
                    "frame \(frame.index): crop corner (\(corner.x), \(corner.y)) samples (\(x), \(y)), outside the frame",
                    file: file, line: line
                )
            }
        }
    }

    func assertRect(_ actual: CGRect, equals expected: CGRect, accuracy: CGFloat, _ message: String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: accuracy, "minX \(message)", file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: accuracy, "minY \(message)", file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: accuracy, "width \(message)", file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: accuracy, "height \(message)", file: file, line: line)
    }

    // MARK: - Analytic cases

    func testTranslateLinearCropMatchesTheAnalyticRectangle() throws {
        // 40 px of total drift in x. Stabilized frame i occupies x in [-tx_i, 1920 - tx_i], so
        // the common region is x in [0, 1880] and all of y. The crop is width-limited:
        // 1880 x 1057.5, centered on x = 940 and (by tie-break toward the frame center) y = 540.
        let (motion, size) = try Self.motion(fixture: "translate-linear")
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)

        let scale = 1880.0 / 1920.0
        assertRect(path.crop, equals: CGRect(x: 0, y: 540 - 1080 * scale / 2, width: 1880, height: 1080 * scale), accuracy: 1)
        XCTAssertEqual(path.cropRetention, scale * scale, accuracy: 1e-6)
    }

    func testCropAnalyticResultDoesNotDependOnWhichFrameIsTheReference() throws {
        // Mid-clip reference (the key photo is usually not frame 0): drift is now -20...+20
        // about the reference, so the common region is x in [20, 1900]. Same size, shifted.
        let (motion, size) = try Self.motion(fixture: "translate-linear", referenceIndex: 45)
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)

        let tx45 = 40.0 * 45.0 / 89.0
        let scale = 1880.0 / 1920.0
        assertRect(
            path.crop,
            equals: CGRect(x: 40.0 - tx45, y: 540 - 1080 * scale / 2, width: 1880, height: 1080 * scale),
            accuracy: 1
        )
        assertCropCornersInsideEveryFrame(path, motion: motion, size: size)
    }

    func testCropRetentionForAHandComputedCase() throws {
        // One frame magnified 2x about the frame center. Stabilizing it shrinks it to the
        // central half in each dimension, so the crop is exactly that central half:
        // scale 0.5, retention 0.25, rect (480, 270, 960, 540).
        let zoom = simd_float3x3(rows: [
            SIMD3<Float>(2, 0, -960), SIMD3<Float>(0, 2, -540), SIMD3<Float>(0, 0, 1),
        ])
        let motion = [
            FrameMotion(index: 0, transform: matrix_identity_float3x3),
            FrameMotion(index: 1, transform: zoom),
        ]
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: frameSize)

        XCTAssertEqual(path.cropRetention, 0.25, accuracy: 1e-6)
        assertRect(path.crop, equals: CGRect(x: 480, y: 270, width: 960, height: 540), accuracy: 0.01)
    }

    func testIdentityMotionKeepsTheWholeFrame() throws {
        let motion = (0..<5).map { FrameMotion(index: $0, transform: matrix_identity_float3x3) }
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: frameSize)
        XCTAssertEqual(path.cropRetention, 1, accuracy: 1e-6)
        assertRect(path.crop, equals: CGRect(origin: .zero, size: frameSize), accuracy: 0.01)
    }

    func testCorrectionsInvertTheMotionInOrder() throws {
        let (motion, size) = try Self.motion(fixture: "combined")
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
        XCTAssertEqual(path.corrections.count, motion.count)
        for (frame, correction) in zip(motion, path.corrections) {
            let product = correction * frame.transform
            for column in 0..<3 {
                for row in 0..<3 {
                    let expected: Float = column == row ? 1 : 0
                    XCTAssertEqual(product[column][row], expected, accuracy: 1e-3, "frame \(frame.index)")
                }
            }
        }
    }

    // MARK: - Every fixture

    func testNoBlackEdgesAndSourceAspectRatioOnEveryFixture() throws {
        var report = "fixture,cropRetention,cropX,cropY,cropW,cropH\n"
        for name in Self.allFixtures {
            let (motion, size) = try Self.motion(fixture: name)
            let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)

            assertCropCornersInsideEveryFrame(path, motion: motion, size: size)
            XCTAssertEqual(
                path.crop.width / path.crop.height, size.width / size.height, accuracy: 1e-6,
                "\(name): crop aspect ratio must equal the source's"
            )
            XCTAssertEqual(path.cropRetention, (path.crop.width * path.crop.height) / (size.width * size.height), accuracy: 1e-9)
            XCTAssertGreaterThan(path.cropRetention, 0)
            report += String(format: "%@,%.4f,%.1f,%.1f,%.1f,%.1f\n", name, path.cropRetention,
                             path.crop.minX, path.crop.minY, path.crop.width, path.crop.height)
        }
        print("\n=== WarpToReferenceSolver crop retention per synthetic fixture ===\n\(report)")
    }

    func testRotateCropIsInsideTheRotatedIntersectionWithNoBlackCorners() throws {
        // The explicit corner-opacity check the issue names, on the rotating fixture.
        let (motion, size) = try Self.motion(fixture: "rotate")
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
        assertCropCornersInsideEveryFrame(path, motion: motion, size: size)
        XCTAssertLessThan(path.cropRetention, 1)
    }

    func testCropIsMaximal() throws {
        // Not just valid but largest: growing the crop by 1% about its center must put some
        // corner of some frame outside.
        let (motion, size) = try Self.motion(fixture: "combined")
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
        let grown = CGRect(
            x: path.crop.midX - path.crop.width * 0.505, y: path.crop.midY - path.crop.height * 0.505,
            width: path.crop.width * 1.01, height: path.crop.height * 1.01
        )
        let corners = [
            CGPoint(x: grown.minX, y: grown.minY), CGPoint(x: grown.maxX, y: grown.minY),
            CGPoint(x: grown.maxX, y: grown.maxY), CGPoint(x: grown.minX, y: grown.maxY),
        ]
        var anyOutside = false
        for frame in motion {
            for corner in corners {
                let p = frame.transform * SIMD3<Float>(Float(corner.x), Float(corner.y), 1)
                let x = p.x / p.z, y = p.y / p.z
                if x < 0 || x > Float(size.width) || y < 0 || y > Float(size.height) { anyOutside = true }
            }
        }
        XCTAssertTrue(anyOutside, "a 1% larger crop should not fit, so the solver left crop on the table")
    }

    // MARK: - Failures

    func testEmptyIntersectionThrowsADescriptiveError() {
        let lurch = simd_float3x3(rows: [
            SIMD3<Float>(1, 0, 5000), SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 0, 1),
        ])
        let motion = [
            FrameMotion(index: 0, transform: matrix_identity_float3x3),
            FrameMotion(index: 7, transform: lurch),
        ]
        XCTAssertThrowsError(try WarpToReferenceSolver().solve(motion: motion, frameSize: frameSize)) { error in
            XCTAssertEqual(error as? CameraPathError, .noCommonRegion(frameIndex: 7))
            XCTAssertTrue("\(error)".contains("frame 7"), "\(error)")
        }
    }

    func testSingularTransformThrows() {
        let singular = simd_float3x3(rows: [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 0), SIMD3<Float>(0, 0, 1),
        ])
        let motion = [FrameMotion(index: 3, transform: singular)]
        XCTAssertThrowsError(try WarpToReferenceSolver().solve(motion: motion, frameSize: frameSize)) { error in
            XCTAssertEqual(error as? CameraPathError, .singularTransform(frameIndex: 3))
        }
    }

    func testNoMotionAndBadFrameSizeThrow() {
        XCTAssertThrowsError(try WarpToReferenceSolver().solve(motion: [], frameSize: frameSize)) {
            XCTAssertEqual($0 as? CameraPathError, .noMotion)
        }
        let motion = [FrameMotion(index: 0, transform: matrix_identity_float3x3)]
        XCTAssertThrowsError(try WarpToReferenceSolver().solve(motion: motion, frameSize: .zero)) {
            XCTAssertEqual($0 as? CameraPathError, .invalidFrameSize(.zero))
        }
    }
}
