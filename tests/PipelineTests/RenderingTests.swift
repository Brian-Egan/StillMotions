import AVFoundation
import CoreImage
import XCTest
import simd
@testable import StillMotionsPipeline

final class RenderingTests: XCTestCase {
    let context = CIContext()

    // MARK: - Helpers

    static func decode(fixture: String, limit: Int? = nil) async throws -> [CVPixelBuffer] {
        let url = CameraPathTests.fixturesDirectory.appendingPathComponent("\(fixture).mov")
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        var frames: [CVPixelBuffer] = []
        for buffer in try FrameSequence.make(asset: asset, track: track) {
            frames.append(buffer)
            if let limit, frames.count == limit { break }
        }
        return frames
    }

    static func simd(_ t: CGAffineTransform) -> simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(Float(t.a), Float(t.b), 0),
            SIMD3<Float>(Float(t.c), Float(t.d), 0),
            SIMD3<Float>(Float(t.tx), Float(t.ty), 1)
        ))
    }

    struct Pixels {
        let width: Int, height: Int
        var bgra: [UInt8]
        func luma(_ x: Int, _ y: Int) -> Double {
            let p = (y * width + x) * 4
            return 0.114 * Double(bgra[p]) + 0.587 * Double(bgra[p + 1]) + 0.299 * Double(bgra[p + 2])
        }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bgra[(y * width + x) * 4 + 3] }
    }

    static func read(_ buffer: CVPixelBuffer) -> Pixels {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<(width * 4) { out[y * width * 4 + x] = base[y * stride + x] }
        }
        return Pixels(width: width, height: height, bgra: out)
    }

    /// A black frame with one white square, built through Core Image so its position is
    /// exact in Core Image coordinates (origin bottom-left).
    func markerFrame(center: CGPoint, side: CGFloat, size: CGSize) throws -> CVPixelBuffer {
        let square = CIImage(color: .white).cropped(to: CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side))
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &out)
        let buffer = try XCTUnwrap(out)
        context.render(square.composited(over: black), to: buffer, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
        return buffer
    }

    /// Brightness-weighted centroid in Core Image coordinates.
    static func centroid(of pixels: Pixels) -> CGPoint {
        var sum = 0.0, sx = 0.0, sy = 0.0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let w = pixels.luma(x, y)
                sum += w
                sx += w * (Double(x) + 0.5)
                sy += w * (Double(pixels.height - y) - 0.5) // buffer rows run top-down; CI y runs up
            }
        }
        return CGPoint(x: sx / sum, y: sy / sum)
    }

    // MARK: - Geometry

    func testWarpedFrameLandsWhereTheTransformSaysWithinOnePixel() throws {
        let source = CGSize(width: 1920, height: 1080)
        let markerAt = CGPoint(x: 700, y: 400)
        let frame = try markerFrame(center: markerAt, side: 40, size: source)

        // A correction with translation and rotation, then a crop scaled down to 720 wide.
        let correction = CGAffineTransform(translationX: -960, y: -540)
            .concatenating(CGAffineTransform(rotationAngle: 1.5 * .pi / 180))
            .concatenating(CGAffineTransform(translationX: 960 - 37.5, y: 540 + 12.25))
        let crop = CGRect(x: 100, y: 50, width: 1700, height: 956.25)
        let outputSize = CGSize(width: 720, height: 405)

        let out = try StabilizedRenderer(context: context).render(
            frame: frame, correction: Self.simd(correction), crop: crop, outputSize: outputSize
        )

        let expectedInReference = markerAt.applying(correction)
        let expected = CGPoint(
            x: (expectedInReference.x - crop.minX) * outputSize.width / crop.width,
            y: (expectedInReference.y - crop.minY) * outputSize.height / crop.height
        )
        let actual = Self.centroid(of: Self.read(out))
        print("marker: expected (\(expected.x), \(expected.y)), got (\(actual.x), \(actual.y))")
        XCTAssertEqual(actual.x, expected.x, accuracy: 1.0)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1.0)
    }

    func testStabilizedFrameMatchesTheReferenceOnTranslateLinear() async throws {
        let (motion, size) = try CameraPathTests.motion(fixture: "translate-linear")
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
        let frames = try await Self.decode(fixture: "translate-linear")
        let renderer = StabilizedRenderer(context: context)
        let outputSize = OutputSize.size(forCrop: path.crop, longEdge: nil)

        let reference = Self.read(try renderer.render(frame: frames[0], correction: path.corrections[0], crop: path.crop, outputSize: outputSize))
        let corrected = Self.read(try renderer.render(frame: frames[89], correction: path.corrections[89], crop: path.crop, outputSize: outputSize))
        let uncorrected = Self.read(try renderer.render(frame: frames[89], correction: matrix_identity_float3x3, crop: path.crop, outputSize: outputSize))

        func meanAbsoluteError(_ a: Pixels, _ b: Pixels) -> Double {
            var sum = 0.0
            for y in 0..<a.height { for x in 0..<a.width { sum += abs(a.luma(x, y) - b.luma(x, y)) } }
            return sum / Double(a.width * a.height)
        }
        let fixed = meanAbsoluteError(reference, corrected)
        let broken = meanAbsoluteError(reference, uncorrected)
        print("translate-linear frame 89 vs reference over the crop: stabilized MAE \(fixed), unstabilized MAE \(broken) (0-255 luma)")
        // The clips are H.264, so some error is compression, not geometry. What matters is
        // that stabilizing removes nearly all of the 40 px misalignment.
        XCTAssertLessThan(fixed, broken / 10)
    }

    // MARK: - Edges

    func testNoTransparentOrBlackEdgesOnAnyFixture() async throws {
        let renderer = StabilizedRenderer(context: context)
        for name in CameraPathTests.allFixtures {
            let (motion, size) = try CameraPathTests.motion(fixture: name)
            let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
            let frames = try await Self.decode(fixture: name)
            let outputSize = OutputSize.size(forCrop: path.crop, longEdge: 720)
            for index in [0, 30, 60, 89] {
                // clampEdges off: anything outside the source frame stays transparent, so a
                // corner that is not fully opaque IS a black edge.
                let out = Self.read(try renderer.render(
                    frame: frames[index], correction: path.corrections[index], crop: path.crop,
                    outputSize: outputSize, clampEdges: false
                ))
                let w = out.width, h = out.height
                for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w / 2, 0), (w / 2, h - 1), (0, h / 2), (w - 1, h / 2)] {
                    XCTAssertGreaterThanOrEqual(out.alpha(x, y), 250, "\(name) frame \(index): pixel (\(x), \(y)) is not opaque")
                }
            }
        }
    }

    // MARK: - Cache

    func testCacheReadsDoNotRender() async throws {
        let frames = try await Self.decode(fixture: "combined", limit: 20)
        let corrections = [simd_float3x3](repeating: matrix_identity_float3x3, count: 20)
        let cache = try StabilizedFrameCache.build(
            frames: frames, corrections: corrections, sourceSize: CGSize(width: 1920, height: 1080),
            renderer: StabilizedRenderer(context: context)
        )
        XCTAssertEqual(cache.count, 20)
        XCTAssertEqual(cache.frameSize, CGSize(width: 720, height: 405))
        XCTAssertEqual(cache.renderCount, 20)

        let rendersBefore = cache.renderCount
        let crop = CGRect(x: 100, y: 60, width: 1500, height: 843.75)
        for index in 0..<20 {
            let view = cache.image(at: index, sourceRect: crop)
            // Core Image snaps a cropped extent outward to whole pixels.
            XCTAssertEqual(view.extent.width, crop.width * cache.scale, accuracy: 1)
            _ = cache.frame(at: index)
        }
        XCTAssertEqual(cache.frames(in: 5..<12).count, 7)
        XCTAssertEqual(cache.renderCount, rendersBefore, "reads must not re-render")
    }

    func testOutputSizing() {
        let crop = CGRect(x: 0, y: 0, width: 1880, height: 1057.5)
        XCTAssertEqual(OutputSize.size(forCrop: crop, longEdge: 720), CGSize(width: 720, height: 404))
        XCTAssertEqual(OutputSize.size(forCrop: crop, longEdge: 480), CGSize(width: 480, height: 270))
        XCTAssertEqual(OutputSize.size(forCrop: crop, longEdge: nil), CGSize(width: 1880, height: 1058))
        XCTAssertEqual(OutputSize.size(forCrop: crop, longEdge: 4000), CGSize(width: 1880, height: 1058), "never upscales")
    }

    // MARK: - Memory and speed

    static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Growth in resident memory after streaming `count` frames through the renderer.
    func footprintGrowth(streaming count: Int, from frames: [CVPixelBuffer]) throws -> Double {
        let renderer = StabilizedRenderer(context: context)
        let corrections = [simd_float3x3](repeating: matrix_identity_float3x3, count: count)
        let cycled = (0..<count).lazy.map { frames[$0 % frames.count] }
        let before = Self.footprint()
        var peak = before
        var checksum = 0
        try renderer.renderStream(
            frames: cycled, corrections: corrections,
            crop: CGRect(x: 0, y: 0, width: 1920, height: 1080), outputSize: CGSize(width: 720, height: 405)
        ) { _, buffer in
            checksum &+= Int(CVPixelBufferGetWidth(buffer))
            peak = max(peak, Self.footprint())
        }
        XCTAssertGreaterThan(checksum, 0)
        return Double(peak > before ? peak - before : 0) / 1_048_576
    }

    func testStreamingMemoryDoesNotGrowWithClipLength() async throws {
        let source = try await Self.decode(fixture: "combined", limit: 12)
        _ = try footprintGrowth(streaming: 24, from: source) // warm Core Image's caches
        let short = try footprintGrowth(streaming: 120, from: source)
        let long = try footprintGrowth(streaming: 600, from: source)
        print("streaming peak growth: 120 frames \(short) MB, 600 frames \(long) MB")
        // 600 frames of 720x405 BGRA would be 700 MB if they were retained.
        XCTAssertLessThan(long - short, 40)
        XCTAssertLessThan(long, 150)
    }

    func testReportRenderTime() async throws {
        let (motion, size) = try CameraPathTests.motion(fixture: "combined")
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
        let frames = try await Self.decode(fixture: "combined", limit: 30)
        let renderer = StabilizedRenderer(context: context)

        func measure(longEdge: Int?) throws -> Double {
            let outputSize = OutputSize.size(forCrop: path.crop, longEdge: longEdge)
            _ = try renderer.render(frame: frames[0], correction: path.corrections[0], crop: path.crop, outputSize: outputSize)
            let start = DispatchTime.now()
            try renderer.renderStream(
                frames: frames, corrections: Array(path.corrections.prefix(frames.count)), crop: path.crop, outputSize: outputSize
            ) { _, buffer in
                // Core Image can queue GPU work and return early; reading a pixel back waits
                // for it, so the timing covers finished frames.
                CVPixelBufferLockBaseAddress(buffer, .readOnly)
                _ = CVPixelBufferGetBaseAddress(buffer)!.load(as: UInt8.self)
                CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            }
            return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000 / Double(frames.count)
        }
        let preview = try measure(longEdge: 720)
        let native = try measure(longEdge: nil)
        print("=== StabilizedRenderer (Core Image), macOS build machine, NOT the iPhone 14 Pro ===")
        print("720 px long edge: \(String(format: "%.2f", preview)) ms/frame")
        print("native crop:      \(String(format: "%.2f", native)) ms/frame")
    }
}
