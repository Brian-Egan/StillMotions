import AVFoundation
import CoreMedia
import XCTest
@testable import StillMotionsPipeline

final class VideoEncoderTests: XCTestCase {
    override func setUpWithError() throws {
        // A hosted CI VM may have no HEVC encoder. Skip loudly rather than fail for a reason
        // that has nothing to do with the code; local runs (and any Mac with an encoder)
        // exercise everything.
        try XCTSkipUnless(
            VideoEncoder.isHEVCEncoderAvailable(),
            "SKIPPED: no HEVC encoder on this machine, so the MP4 encoder is NOT being verified here"
        )
    }

    // MARK: - Helpers

    func tempURL(_ name: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name).mp4")
    }

    struct Inspection {
        let isPlayable: Bool
        let codec: FourCharCode?
        let nominalFrameRate: Float
        let sampleCount: Int
        let size: CGSize
    }

    /// Reads the written file back: playable, codec, rate, and the real number of samples.
    func inspect(_ url: URL) async throws -> Inspection {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let formats = try await track.load(.formatDescriptions)
        let reader = try AVAssetReader(asset: asset)
        // nil settings: compressed samples as written, so the count is the file's own.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        // Reading compressed samples also yields marker buffers that carry no frame (NaN
        // timestamps, empty); only buffers holding samples count as frames.
        while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
        return Inspection(
            isPlayable: try await asset.load(.isPlayable),
            codec: formats.first.map { CMFormatDescriptionGetMediaSubType($0) },
            nominalFrameRate: try await track.load(.nominalFrameRate),
            sampleCount: count,
            size: try await track.load(.naturalSize)
        )
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
        memset(CVPixelBufferGetBaseAddress(buffer)!, Int32(shade), CVPixelBufferGetBytesPerRow(buffer) * height)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    // MARK: - Acceptance

    func testEveryFixtureEncodesAtEveryPreset() async throws {
        for fixture in CameraPathTests.allFixtures {
            let path = try solvedPath(fixture)
            let movie = CameraPathTests.fixturesDirectory.appendingPathComponent("\(fixture).mov")
            for preset in SizePreset.allCases {
                let url = tempURL("\(fixture)-\(preset.rawValue)")
                defer { try? FileManager.default.removeItem(at: url) }
                let result = try await ClipExporter.exportVideo(movieURL: movie, path: path, preset: preset, mode: .once, to: url)

                let expected = OutputSize.size(forCrop: path.crop, longEdge: preset.longEdge)
                let info = try await inspect(url)
                XCTAssertEqual(result.frameCount, 90, "\(fixture) \(preset)")
                XCTAssertEqual(CGSize(width: result.width, height: result.height), expected, "\(fixture) \(preset)")
                XCTAssertTrue(info.isPlayable, "\(fixture) \(preset) is not playable")
                XCTAssertEqual(info.codec, kCMVideoCodecType_HEVC, "\(fixture) \(preset) is not HEVC")
                XCTAssertEqual(info.sampleCount, 90, "\(fixture) \(preset)")
                XCTAssertEqual(info.size, expected, "\(fixture) \(preset)")
                // The output frame rate equals the source's (30 fps by construction).
                XCTAssertEqual(info.nominalFrameRate, 30, accuracy: 0.01, "\(fixture) \(preset)")
            }
        }
    }

    func testBounceWritesTwoNMinusOneFrames() async throws {
        let path = try solvedPath("translate-shake")
        let movie = CameraPathTests.fixturesDirectory.appendingPathComponent("translate-shake.mov")
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await ClipExporter.exportVideo(movieURL: movie, path: path, preset: .small, mode: .bounce, to: url)
        XCTAssertEqual(result.frameCount, 2 * 90 - 1)
        let info = try await inspect(url)
        XCTAssertEqual(info.sampleCount, 179)
        XCTAssertEqual(info.nominalFrameRate, 30, accuracy: 0.01)
    }

    func testBounceReplaysTheClipBackwards() async throws {
        // Five frames of rising brightness, bounced: 1 2 3 4 5 4 3 2 1.
        let frames = (1...5).map { Self.solidBuffer(width: 64, height: 64, shade: UInt8($0 * 40)) }
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await VideoEncoder().encode(frames: frames, frameRate: 30, mode: .bounce, to: url)
        XCTAssertEqual(result.frameCount, 9)

        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        reader.startReading()
        var shades: [Int] = []
        while let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            shades.append(Int(CVPixelBufferGetBaseAddress(buffer)!.load(fromByteOffset: 32 * 4 + 32 * CVPixelBufferGetBytesPerRow(buffer), as: UInt8.self)))
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        let ranks = shades.map { Int((Double($0) / 40).rounded()) }
        XCTAssertEqual(ranks, [1, 2, 3, 4, 5, 4, 3, 2, 1], "shades \(shades)")
    }

    func testLoopModeThrowsADescriptiveErrorBeforeDoingAnyWork() async throws {
        let path = try solvedPath("translate-linear")
        let missing = URL(fileURLWithPath: "/nonexistent/clip.mov")
        do {
            _ = try await ClipExporter.exportVideo(movieURL: missing, path: path, preset: .small, mode: .loop, to: tempURL())
            XCTFail("expected an error")
        } catch let error as VideoEncodingError {
            // The missing file would have thrown a different error had decoding started.
            guard case .loopNotSupported = error else { return XCTFail("wrong error \(error)") }
            XCTAssertTrue("\(error)".contains("GIF"), "the message should point to GIF: \(error)")
        }
    }

    func testFrameRateIsPreservedForFractionalRates() async throws {
        let frames = (0..<30).map { _ in Self.solidBuffer(width: 64, height: 64, shade: 100) }
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await VideoEncoder().encode(frames: frames, frameRate: 29.97, mode: .once, to: url)
        let info = try await inspect(url)
        XCTAssertEqual(info.nominalFrameRate, 29.97, accuracy: 0.02)
    }

    // MARK: - Robustness

    func testFrameSizeChangeAndEmptyInputFail() async throws {
        let url = tempURL()
        let mixed = [Self.solidBuffer(width: 64, height: 64, shade: 1), Self.solidBuffer(width: 66, height: 64, shade: 1)]
        do {
            _ = try await VideoEncoder().encode(frames: mixed, frameRate: 30, mode: .once, to: url)
            XCTFail("expected a size error")
        } catch let error as VideoEncodingError {
            guard case .frameSizeChanged = error else { return XCTFail("wrong error \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a failed encode must not leave a file")

        do {
            _ = try await VideoEncoder().encode(frames: [CVPixelBuffer](), frameRate: 30, mode: .once, to: url)
            XCTFail("expected noFrames")
        } catch let error as VideoEncodingError {
            guard case .noFrames = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testCancellationStopsTheEncodeAndRemovesThePartialFile() async throws {
        let url = tempURL()
        let task = Task {
            // Built inside the task so nothing non-Sendable is captured across it.
            let frame = Self.solidBuffer(width: 128, height: 128, shade: 77)
            var produced = 0
            return try await VideoEncoder().encode(
                nextFrame: { produced += 1; return produced < 100_000 ? frame : nil },
                frameRate: 30, mode: .once, to: url
            )
        }
        try await Task.sleep(for: .milliseconds(150))
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

    /// Peak growth while encoding `count` generated 1280x720 frames.
    func peakGrowth(count: Int, mode: PlaybackMode) async throws -> Double {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let shades = (0..<8).map { Self.solidBuffer(width: 1280, height: 720, shade: UInt8($0 * 30)) }
        let before = footprint()
        var peak = before
        var index = 0
        _ = try await VideoEncoder().encode(
            nextFrame: {
                defer { index += 1 }
                peak = max(peak, self.footprint())
                return index < count ? shades[index % shades.count] : nil
            },
            frameRate: 30, mode: mode, to: url
        )
        return Double(peak > before ? peak - before : 0) / 1_048_576
    }

    func testPeakMemoryDoesNotGrowWithClipLength() async throws {
        for mode in [PlaybackMode.once, .bounce] {
            _ = try await peakGrowth(count: 20, mode: mode) // warm the encoder
            let short = try await peakGrowth(count: 60, mode: mode)
            let long = try await peakGrowth(count: 300, mode: mode)
            print("\(mode) encode peak growth: 60 frames \(short) MB, 300 frames \(long) MB")
            // 300 frames of 1280x720 BGRA are ~1 GB if retained.
            XCTAssertLessThan(long - short, 80, "\(mode)")
            XCTAssertLessThan(long, 250, "\(mode)")
        }
    }

    // MARK: - Spool

    func testSpoolReturnsFramesByIndexInAnyOrder() throws {
        let spool = try FrameSpool(width: 33, height: 17) // odd width: rows are not 16-byte aligned
        for shade in 0..<6 { try spool.append(Self.solidBuffer(width: 33, height: 17, shade: UInt8(shade * 10))) }
        XCTAssertEqual(spool.count, 6)
        for index in [5, 0, 3, 3, 1] {
            let buffer = try spool.buffer(at: index)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let first = CVPixelBufferGetBaseAddress(buffer)!.load(as: UInt8.self)
            let last = CVPixelBufferGetBaseAddress(buffer)!.load(fromByteOffset: 16 * CVPixelBufferGetBytesPerRow(buffer) + 32 * 4 + 3, as: UInt8.self)
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            XCTAssertEqual(first, UInt8(index * 10))
            XCTAssertEqual(last, UInt8(index * 10))
        }
        XCTAssertThrowsError(try spool.buffer(at: 6))
        XCTAssertThrowsError(try spool.append(Self.solidBuffer(width: 34, height: 17, shade: 0)))
    }
}
