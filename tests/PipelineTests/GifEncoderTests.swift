import AVFoundation
import ImageIO
import XCTest
@testable import StillMotionsPipeline

/// What a GIF file actually says, read from its bytes. Tests assert on this, not on what the
/// encoder was asked to do.
struct GifFacts: Equatable {
    var width = 0
    var height = 0
    var frameDelays: [Int] = [] // centiseconds
    /// `nil` when there is no NETSCAPE looping extension (plays once); else the repeat count,
    /// where 0 means forever.
    var loopCount: Int?

    static func parse(_ url: URL) throws -> GifFacts {
        let bytes = [UInt8](try Data(contentsOf: url))
        guard bytes.count > 13, String(decoding: bytes[0..<3], as: UTF8.self) == "GIF" else {
            throw XCTSkip("not a GIF")
        }
        var facts = GifFacts()
        facts.width = Int(bytes[6]) | Int(bytes[7]) << 8
        facts.height = Int(bytes[8]) | Int(bytes[9]) << 8
        var i = 13
        if bytes[10] & 0x80 != 0 { i += 3 * (1 << (Int(bytes[10] & 0x07) + 1)) }

        func skipSubBlocks() {
            while i < bytes.count, bytes[i] != 0 { i += Int(bytes[i]) + 1 }
            i += 1
        }
        while i < bytes.count {
            switch bytes[i] {
            case 0x21: // extension
                let label = bytes[i + 1]
                if label == 0xF9 { // graphic control: block size 4, flags, delay (LE), transparent, 0
                    facts.frameDelays.append(Int(bytes[i + 4]) | Int(bytes[i + 5]) << 8)
                    i += 8
                } else if label == 0xFF { // application
                    let name = String(decoding: bytes[(i + 3)..<(i + 14)], as: UTF8.self)
                    if name == "NETSCAPE2.0", bytes[i + 14] == 3, bytes[i + 15] == 1 {
                        facts.loopCount = Int(bytes[i + 16]) | Int(bytes[i + 17]) << 8
                    }
                    i += 14
                    skipSubBlocks()
                } else {
                    i += 2
                    skipSubBlocks()
                }
            case 0x2C: // image
                let flags = bytes[i + 9]
                i += 10
                if flags & 0x80 != 0 { i += 3 * (1 << (Int(flags & 0x07) + 1)) }
                i += 1 // LZW minimum code size
                skipSubBlocks()
            case 0x3B:
                return facts
            default:
                throw XCTSkip("unexpected GIF block 0x\(String(bytes[i], radix: 16)) at \(i)")
            }
        }
        return facts
    }
}

final class GifEncoderTests: XCTestCase {
    func tempURL(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name).gif")
    }

    func solvedPath(_ fixture: String) throws -> CameraPath {
        let (motion, size) = try CameraPathTests.motion(fixture: fixture)
        return try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
    }

    static func solidBuffer(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &out)
        let buffer = out!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                // A diagonal gradient so each frame is a real picture, not one flat colour.
                let v = UInt8((Int(shade) + x + y) % 256)
                let p = base + y * stride + x * 4
                p[0] = v; p[1] = UInt8((Int(v) + 60) % 256); p[2] = UInt8((Int(v) + 120) % 256); p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    /// Frames ImageIO can decode: the GIF is valid and playable.
    func decodedFrameCount(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return 0 }
        return CGImageSourceGetCount(source)
    }

    // MARK: - Frame rates

    func testFrameRatesAreExactCentisecondsAndDecimateCorrectly() {
        XCTAssertEqual(GifFrameRate.allCases.map(\.centiseconds), [6, 5, 4])
        XCTAssertEqual(GifFrameRate.fps20.framesPerSecond, 20)
        // 3 s at 30 fps: 50, 60 and 75 frames.
        XCTAssertEqual(GifFrameRate.fps16_67.sourceIndices(sourceCount: 90, sourceRate: 30).count, 50)
        XCTAssertEqual(GifFrameRate.fps20.sourceIndices(sourceCount: 90, sourceRate: 30).count, 60)
        XCTAssertEqual(GifFrameRate.fps25.sourceIndices(sourceCount: 90, sourceRate: 30).count, 75)
        // 20 fps from 30 fps takes 2 of every 3 source frames, nearest to each output tick.
        XCTAssertEqual(Array(GifFrameRate.fps20.sourceIndices(sourceCount: 90, sourceRate: 30).prefix(6)), [0, 2, 3, 5, 6, 8])
        let indices = GifFrameRate.fps20.sourceIndices(sourceCount: 90, sourceRate: 30)
        XCTAssertEqual(indices, indices.sorted())
        XCTAssertLessThan(indices.last!, 90)
        // A source slower than the output repeats frames rather than running out.
        XCTAssertEqual(GifFrameRate.fps25.sourceIndices(sourceCount: 15, sourceRate: 15).count, 25)
    }

    // MARK: - Acceptance

    func testEveryFixtureEncodesAtEveryPreset() async throws {
        for fixture in CameraPathTests.allFixtures {
            let path = try solvedPath(fixture)
            let movie = CameraPathTests.fixturesDirectory.appendingPathComponent("\(fixture).mov")
            for preset in SizePreset.allCases {
                let url = tempURL("\(fixture)-\(preset.rawValue)")
                defer { try? FileManager.default.removeItem(at: url) }
                let result = try await ClipExporter.exportGIF(
                    movieURL: movie, path: path, preset: preset, frameRate: .fps20, mode: .loop, to: url
                )
                let expected = OutputSize.size(forCrop: path.crop, longEdge: preset.longEdge)
                let facts = try GifFacts.parse(url)

                XCTAssertEqual(result.frameCount, 60, "\(fixture) \(preset)")
                XCTAssertEqual(CGSize(width: facts.width, height: facts.height), expected, "\(fixture) \(preset)")
                XCTAssertEqual(facts.frameDelays.count, 60, "\(fixture) \(preset)")
                XCTAssertEqual(decodedFrameCount(url), 60, "\(fixture) \(preset) is not playable")
                XCTAssertEqual(facts.loopCount, 0, "\(fixture) \(preset): Loop must repeat forever")
            }
        }
    }

    func testEveryFrameRateGivesExactDelaysAndFrameCounts() async throws {
        let path = try solvedPath("translate-shake")
        let movie = CameraPathTests.fixturesDirectory.appendingPathComponent("translate-shake.mov")
        for (rate, expectedFrames) in [(GifFrameRate.fps16_67, 50), (.fps20, 60), (.fps25, 75)] {
            for preset in SizePreset.allCases {
                let url = tempURL()
                defer { try? FileManager.default.removeItem(at: url) }
                _ = try await ClipExporter.exportGIF(movieURL: movie, path: path, preset: preset, frameRate: rate, mode: .loop, to: url)
                let facts = try GifFacts.parse(url)
                XCTAssertEqual(facts.frameDelays.count, expectedFrames, "\(rate) \(preset)")
                // Every frame, including the last, is exactly one frame time.
                XCTAssertEqual(Set(facts.frameDelays), [rate.centiseconds], "\(rate) \(preset): delays \(Set(facts.frameDelays))")
            }
        }
    }

    func testLoopCountPerMode() async throws {
        let path = try solvedPath("translate-linear")
        let movie = CameraPathTests.fixturesDirectory.appendingPathComponent("translate-linear.mov")
        var counts: [PlaybackMode: Int?] = [:]
        for mode in PlaybackMode.allCases {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try await ClipExporter.exportGIF(movieURL: movie, path: path, preset: .small, frameRate: .fps20, mode: mode, to: url)
            counts[mode] = .some(try GifFacts.parse(url).loopCount)
            XCTAssertEqual(result.loopForever, mode != .once)
        }
        // Parsed from the Netscape application extension in the file itself.
        XCTAssertEqual(counts[.loop], .some(0), "Loop repeats forever")
        XCTAssertEqual(counts[.bounce], .some(0), "Bounce is a palindrome, so it repeats forever")
        XCTAssertEqual(counts[.once], .some(nil), "Once has no looping extension and plays a single time")
    }

    func testBounceWritesTwoNMinusOneFrames() async throws {
        let path = try solvedPath("rotate")
        let movie = CameraPathTests.fixturesDirectory.appendingPathComponent("rotate.mov")
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await ClipExporter.exportGIF(movieURL: movie, path: path, preset: .small, frameRate: .fps20, mode: .bounce, to: url)
        XCTAssertEqual(result.frameCount, 2 * 60 - 1)
        let facts = try GifFacts.parse(url)
        XCTAssertEqual(facts.frameDelays.count, 119)
        XCTAssertEqual(Set(facts.frameDelays), [5])
        XCTAssertEqual(decodedFrameCount(url), 119)
    }

    func testTrimLimitsTheExportedRange() async throws {
        let path = try solvedPath("translate-linear")
        let movie = CameraPathTests.fixturesDirectory.appendingPathComponent("translate-linear.mov")
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // 30 source frames = 1 s = 20 GIF frames at 20 fps.
        let result = try await ClipExporter.exportGIF(
            movieURL: movie, path: path, preset: .small, frameRate: .fps20, mode: .once, trim: 30..<60, to: url
        )
        XCTAssertEqual(result.frameCount, 20)
    }

    // MARK: - Robustness

    func testFrameSizeChangeAndEmptyInputFail() async throws {
        let url = tempURL()
        let mixed = [Self.solidBuffer(width: 64, height: 64, shade: 1), Self.solidBuffer(width: 66, height: 64, shade: 1)]
        do {
            _ = try await GifEncoder().encode(frames: mixed, frameRate: .fps20, mode: .once, to: url)
            XCTFail("expected a size error")
        } catch let error as GifEncodingError {
            guard case .frameSizeChanged = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a failed encode must not leave a file")

        do {
            _ = try await GifEncoder().encode(frames: [CVPixelBuffer](), frameRate: .fps20, mode: .once, to: url)
            XCTFail("expected noFrames")
        } catch let error as GifEncodingError {
            guard case .noFrames = error else { return XCTFail("wrong error \(error)") }
        }
    }

    final class EndlessFrames: @unchecked Sendable {
        private let frames = (0..<4).map { GifEncoderTests.solidBuffer(width: 128, height: 128, shade: UInt8($0 * 50)) }
        private var produced = 0
        func next() -> CVPixelBuffer? {
            produced += 1
            return produced < 100_000 ? frames[produced % frames.count] : nil
        }
    }

    func testCancellationStopsTheEncodeAndRemovesThePartialFile() async throws {
        let url = tempURL()
        let source = EndlessFrames()
        let task = Task {
            try await GifEncoder().encode(nextFrame: { source.next() }, frameRate: .fps20, mode: .once, to: url)
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Memory

    func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func peakGrowth(count: Int, mode: PlaybackMode) async throws -> Double {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let pictures = (0..<8).map { Self.solidBuffer(width: 480, height: 270, shade: UInt8($0 * 30)) }
        let before = footprint()
        var peak = before
        var index = 0
        _ = try await GifEncoder().encode(
            nextFrame: {
                defer { index += 1 }
                peak = max(peak, self.footprint())
                return index < count ? pictures[index % pictures.count] : nil
            },
            frameRate: .fps20, mode: mode, to: url
        )
        return Double(peak > before ? peak - before : 0) / 1_048_576
    }

    func testPeakMemoryDoesNotGrowWithClipLength() async throws {
        for mode in [PlaybackMode.once, .bounce] {
            _ = try await peakGrowth(count: 10, mode: mode) // warm up
            let short = try await peakGrowth(count: 40, mode: mode)
            let long = try await peakGrowth(count: 200, mode: mode)
            print("GIF \(mode) peak growth: 40 frames \(short) MB, 200 frames \(long) MB")
            // 200 frames of 480x270 RGBA is ~100 MB if retained.
            XCTAssertLessThan(long - short, 40, "\(mode)")
        }
    }
}
