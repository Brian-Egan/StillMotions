import CoreVideo
import XCTest
import simd
@testable import PipelineCore
@testable import Rendering

/// #31: `ContentFeatures`, the measure of how hard a clip is to compress, taken from the stabilized
/// preview frames. These check that it orders clips the way a GIF encoder would.
final class ContentFeaturesTests: XCTestCase {
    static let size = CGSize(width: 160, height: 120)
    static let whole = CGRect(origin: .zero, size: size)

    /// A frame of `kind` painted straight into a BGRA buffer.
    enum Picture {
        case flat(UInt8)
        case stripes(period: Int)
        case noise(seed: UInt64)
    }

    static func frame(_ picture: Picture) throws -> CVPixelBuffer {
        let buffer = try StabilizedRenderer.makeScratchBuffer(width: Int(size.width), height: Int(size.height))
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var state: UInt64 = { if case .noise(let seed) = picture { return seed &+ 1 } else { return 1 } }()
        for y in 0..<Int(size.height) {
            for x in 0..<Int(size.width) {
                var r: UInt8, g: UInt8, b: UInt8
                switch picture {
                case .flat(let v): (r, g, b) = (v, v, v)
                case .stripes(let period): (r, g, b) = ((x / period) % 2 == 0 ? (30, 30, 30) : (220, 220, 220))
                case .noise:
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    (r, g, b) = (UInt8(truncatingIfNeeded: state >> 56), UInt8(truncatingIfNeeded: state >> 48), UInt8(truncatingIfNeeded: state >> 40))
                }
                let p = base + y * stride + x * 4
                p[0] = b; p[1] = g; p[2] = r; p[3] = 255
            }
        }
        return buffer
    }

    static func features(_ pictures: [Picture]) throws -> ContentFeatures {
        let frames = try pictures.map(frame)
        let cache = try StabilizedFrameCache.build(
            frames: frames, corrections: Array(repeating: matrix_identity_float3x3, count: frames.count), sourceSize: size, longEdge: 160
        )
        return try XCTUnwrap(cache.contentFeatures(crop: whole))
    }

    func testAFlatStillClipHasNoDetailNoChangeAndNoColor() throws {
        let f = try Self.features([.flat(128), .flat(128), .flat(128)])
        XCTAssertLessThan(f.detail, 0.5)
        XCTAssertEqual(f.edgeDensity, 0, accuracy: 0.001)
        XCTAssertEqual(f.change, 0, accuracy: 0.5)
        XCTAssertEqual(f.changeFraction, 0, accuracy: 0.001)
        XCTAssertLessThan(f.colorEntropy, 0.5)
    }

    func testDetailAndEdgesRiseWithFineStructure() throws {
        let flat = try Self.features([.flat(128), .flat(128)])
        let coarse = try Self.features([.stripes(period: 40), .stripes(period: 40)])
        let fine = try Self.features([.stripes(period: 4), .stripes(period: 4)])
        XCTAssertLessThan(flat.detail, coarse.detail)
        XCTAssertLessThan(coarse.detail, fine.detail)
        XCTAssertLessThan(flat.edgeDensity, coarse.edgeDensity)
        XCTAssertLessThan(coarse.edgeDensity, fine.edgeDensity)
    }

    func testChangeBetweenFramesIsSeen() throws {
        let still = try Self.features([.stripes(period: 8), .stripes(period: 8)])
        let moving = try Self.features([.stripes(period: 8), .noise(seed: 3)])
        XCTAssertEqual(still.change, 0, accuracy: 0.5)
        XCTAssertGreaterThan(moving.change, 20)
        XCTAssertGreaterThan(moving.changeFraction, 0.5)
    }

    func testAColorfulFrameNeedsMorePaletteThanAFlatOne() throws {
        let flat = try Self.features([.flat(100), .flat(100)])
        let noisy = try Self.features([.noise(seed: 1), .noise(seed: 2)])
        XCTAssertGreaterThan(noisy.colorEntropy, flat.colorEntropy + 5)
    }

    func testTooFewFramesGiveNoMeasurement() throws {
        let cache = try StabilizedFrameCache.build(
            frames: [try Self.frame(.flat(1))], corrections: [matrix_identity_float3x3], sourceSize: Self.size, longEdge: 160
        )
        XCTAssertNil(cache.contentFeatures(crop: Self.whole))
    }

    func testMeasuringIsQuickEnoughToDoWhenTheEditorOpens() throws {
        let frames = try (0..<40).map { _ in try Self.frame(.noise(seed: 9)) }
        let cache = try StabilizedFrameCache.build(
            frames: frames, corrections: Array(repeating: matrix_identity_float3x3, count: 40), sourceSize: Self.size, longEdge: 160
        )
        let start = ContinuousClock.now
        _ = cache.contentFeatures(crop: Self.whole)
        // A budget on the Mac only to catch an accident (a per-pixel allocation, say); the real
        // cost on the phone is read from the device in #35.
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }
}
