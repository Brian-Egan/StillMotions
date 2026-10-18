import AVFoundation
import CoreVideo
import XCTest
import simd
@testable import Rendering
@testable import StillMotionsPipeline

/// #90: the renderer must not change how bright a picture is. Core Image works in linear light,
/// and writing its result without naming a color space stored those linear numbers as if they were
/// sRGB, so a mid-grey 127 came out as 54, and a crossfade (which reads those frames again) as 9.
final class ColorFidelityTests: XCTestCase {
    /// A BGRA buffer filled with one color.
    static func solid(red: UInt8, green: UInt8, blue: UInt8, width: Int = 64, height: Int = 48) throws -> CVPixelBuffer {
        let buffer = try StabilizedRenderer.makeScratchBuffer(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                p[0] = blue; p[1] = green; p[2] = red; p[3] = 255
            }
        }
        return buffer
    }

    /// Mean (red, green, blue) over the buffer, 0...255.
    static func mean(_ buffer: CVPixelBuffer) -> (r: Double, g: Double, b: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var r = 0.0, g = 0.0, b = 0.0
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                b += Double(p[0]); g += Double(p[1]); r += Double(p[2])
            }
        }
        let n = Double(width * height)
        return (r / n, g / n, b / n)
    }

    static let tolerance = 2.0

    private func assertColor(_ buffer: CVPixelBuffer, _ expected: (r: Double, g: Double, b: Double), _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let m = Self.mean(buffer)
        XCTAssertEqual(m.r, expected.r, accuracy: Self.tolerance, "red: \(message)", file: file, line: line)
        XCTAssertEqual(m.g, expected.g, accuracy: Self.tolerance, "green: \(message)", file: file, line: line)
        XCTAssertEqual(m.b, expected.b, accuracy: Self.tolerance, "blue: \(message)", file: file, line: line)
    }

    func testRenderingKeepsAMidGreyMidGrey() throws {
        let source = try Self.solid(red: 127, green: 127, blue: 127)
        let rendered = try StabilizedRenderer().render(
            frame: source, correction: matrix_identity_float3x3, crop: CGRect(x: 0, y: 0, width: 64, height: 48), outputSize: CGSize(width: 64, height: 48)
        )
        assertColor(rendered, (127, 127, 127), "a rendered frame must be as bright as its source")
    }

    func testRenderingKeepsColorsAndSurvivesScalingAndRepeatedRendering() throws {
        let colors: [(UInt8, UInt8, UInt8)] = [(200, 100, 50), (20, 20, 20), (250, 250, 250), (60, 180, 220)]
        let renderer = StabilizedRenderer()
        for (r, g, b) in colors {
            let source = try Self.solid(red: r, green: g, blue: b)
            let expected = (Double(r), Double(g), Double(b))
            // Scaled down, as the preview cache and the Small preset do.
            let small = try renderer.render(frame: source, correction: matrix_identity_float3x3, crop: CGRect(x: 0, y: 0, width: 64, height: 48), outputSize: CGSize(width: 32, height: 24))
            assertColor(small, expected, "scaled \(r),\(g),\(b)")
            // Rendered again from its own output (the cache is read back by blend and by the exporters).
            let again = try renderer.render(frame: small, correction: matrix_identity_float3x3, crop: CGRect(x: 0, y: 0, width: 32, height: 24), outputSize: CGSize(width: 32, height: 24))
            assertColor(again, expected, "rendered twice \(r),\(g),\(b)")
        }
    }

    func testABlendOfTwoEqualFramesIsTheSameFrame() throws {
        let renderer = StabilizedRenderer()
        for shade: UInt8 in [30, 127, 220] {
            let a = try renderer.render(
                frame: try Self.solid(red: shade, green: shade, blue: shade), correction: matrix_identity_float3x3,
                crop: CGRect(x: 0, y: 0, width: 64, height: 48), outputSize: CGSize(width: 64, height: 48)
            )
            let b = try Self.solid(red: shade, green: shade, blue: shade)
            for weight: Float in [0, 0.25, 0.5, 1] {
                let mixed = try renderer.blend(a, b, weight: weight)
                assertColor(mixed, (Double(shade), Double(shade), Double(shade)), "blend of two \(shade) frames at \(weight): the crossfade must not flash dark")
            }
        }
    }

    func testABlendLiesBetweenItsInputs() throws {
        let renderer = StabilizedRenderer()
        let dark = try Self.solid(red: 40, green: 40, blue: 40), light = try Self.solid(red: 200, green: 200, blue: 200)
        let mixed = Self.mean(try renderer.blend(dark, light, weight: 0.5))
        XCTAssertGreaterThan(mixed.g, 40 + Self.tolerance)
        XCTAssertLessThan(mixed.g, 200 - Self.tolerance)
    }

    /// A portrait Live Photo is stored sideways and turned upright on decode. Turning it must not
    /// change its brightness: the same clip, decoded upright and as stored and then rendered the way
    /// the preview and the exports do, has the same mean color. (The two decode paths hand over
    /// buffers in different encodings, each tagged with its own; what matters is the rendered result.)
    func testTurningAPortraitClipUprightKeepsItsBrightness() async throws {
        let rotate90 = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 32, ty: 0)
        var means: [(r: Double, g: Double, b: Double)] = []
        for transform in [CGAffineTransform.identity, rotate90] {
            let clip = try ImportTests.makeTestClip(
                frameCount: 5, frameRate: 30, frameSize: CGSize(width: 64, height: 32), stillOffsetSeconds: nil, trackTransform: transform
            )
            defer { try? FileManager.default.removeItem(at: clip.directory) }
            let asset = AVURLAsset(url: clip.mov)
            let track = try await asset.loadTracks(withMediaType: .video).first!
            let frames = Array(try FrameSequence.make(asset: asset, track: track))
            let frame = frames[2]
            let size = CGSize(width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))
            let rendered = try StabilizedRenderer().render(
                frame: frame, correction: matrix_identity_float3x3, crop: CGRect(origin: .zero, size: size), outputSize: size
            )
            means.append(Self.mean(rendered))
        }
        XCTAssertEqual(means[1].r, means[0].r, accuracy: Self.tolerance, "red")
        XCTAssertEqual(means[1].g, means[0].g, accuracy: Self.tolerance, "green")
        XCTAssertEqual(means[1].b, means[0].b, accuracy: Self.tolerance, "blue")
    }
}
