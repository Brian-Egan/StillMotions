import AVFoundation
import CoreImage
import XCTest
import simd
@testable import StillMotionsPipeline

/// #64. Real Live Photo video is variable frame rate; the pipeline used to treat every clip as
/// constant rate, so playback speed was wrong on exactly those clips.
final class VariableFrameRateTests: XCTestCase {
    /// Frame times of a clip shot fast for its first 20 frames (30 fps) and slow for its last 10
    /// (6 fps), as a phone does when the light drops. 20/30 + 10/6 = 2.333 s long.
    static let irregularTimes: [Double] = {
        var times = (0..<20).map { Double($0) / 30 }
        let start = 20.0 / 30
        times += (0..<10).map { start + Double($0) / 6 }
        return times
    }()

    // MARK: - FrameTiming

    func testFrameTimingBasics() {
        let times = [10.0, 10.1, 10.2, 10.5]
        let relative = FrameTiming.relative(times)
        XCTAssertEqual(relative[0], 0)
        XCTAssertEqual(relative[3], 0.5, accuracy: 1e-9)
        // 0.5 s to the last frame's start, plus its own length taken as the gap before it (0.3).
        XCTAssertEqual(FrameTiming.duration(of: relative), 0.8, accuracy: 1e-9)
        XCTAssertEqual(FrameTiming.nearestIndex(to: 0.04, in: relative), 0)
        XCTAssertEqual(FrameTiming.nearestIndex(to: 0.06, in: relative), 1)
        XCTAssertEqual(FrameTiming.nearestIndex(to: 0.15, in: relative), 2, "a tie goes to the later frame")
        XCTAssertEqual(FrameTiming.nearestIndex(to: 9, in: relative), 3)
        XCTAssertEqual(FrameTiming.nearestIndex(to: -1, in: relative), 0)
    }

    // MARK: - GIF decimation

    func testGifTicksFollowRealTimeSoTheGifLastsAsLongAsTheClip() {
        let times = Self.irregularTimes
        let clipDuration = FrameTiming.duration(of: FrameTiming.relative(times))
        for rate in GifFrameRate.allCases {
            let byTime = rate.sourceIndices(frameTimes: times)
            let playedByTime = Double(byTime.count) / rate.framesPerSecond
            XCTAssertEqual(playedByTime, clipDuration, accuracy: 1 / rate.framesPerSecond, "\(rate): time-based GIF length")

            // What index-based decimation did: it believed the clip ran at its nominal 30 fps, so
            // 30 frames lasted 1 s, and the GIF was less than half the length of the clip.
            let byIndex = rate.sourceIndices(sourceCount: times.count, sourceRate: 30)
            let playedByIndex = Double(byIndex.count) / rate.framesPerSecond
            XCTAssertLessThan(playedByIndex, clipDuration * 0.6, "\(rate): index-based GIF should be visibly too short")
        }
    }

    func testGifTicksPickTheNearestFrameInTime() {
        let times = Self.irregularTimes
        let indices = GifFrameRate.fps20.sourceIndices(frameTimes: times)
        let relative = FrameTiming.relative(times)
        for (tick, index) in indices.enumerated() {
            let t = Double(tick) / 20
            let chosen = abs(relative[index] - t)
            let best = relative.map { abs($0 - t) }.min()!
            XCTAssertEqual(chosen, best, accuracy: 1e-6, "tick \(tick) at \(t) s picked frame \(index)")
        }
        // In the slow section (frames 20...29, one every 1/6 s) many ticks land on the same frame.
        XCTAssertGreaterThan(Set(indices.filter { $0 >= 20 }).count, 1)
        XCTAssertLessThan(Set(indices.filter { $0 >= 20 }).count, indices.filter { $0 >= 20 }.count)
    }

    func testEvenlySpacedTimesGiveTheSameFramesAsTheConstantRatePath() async throws {
        for fixture in ["translate-shake", "combined", "periodic"] {
            let asset = AVURLAsset(url: CameraPathTests.fixturesDirectory.appendingPathComponent("\(fixture).mov"))
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let times = try FrameSequence.presentationTimes(asset: asset, track: track)
            XCTAssertEqual(times.count, 90)
            for rate in GifFrameRate.allCases {
                XCTAssertEqual(
                    rate.sourceIndices(frameTimes: times),
                    rate.sourceIndices(sourceCount: 90, sourceRate: 30),
                    "\(fixture) at \(rate): constant-rate fixtures must decimate exactly as before"
                )
            }
        }
        // Other common source rates. Some output ticks fall exactly halfway between two source
        // frames (a tick at 16.67 fps of a 25 fps clip is at frame 7.5). The old index arithmetic
        // settled those by floating-point noise; time-based selection always takes the later frame.
        // So the count must match and every pick must be within one frame of the old one.
        for sourceRate in [24.0, 25.0, 30.0, 60.0] {
            let times = (0..<73).map { Double($0) / sourceRate }
            for rate in GifFrameRate.allCases {
                let byTime = rate.sourceIndices(frameTimes: times)
                let byIndex = rate.sourceIndices(sourceCount: 73, sourceRate: sourceRate)
                XCTAssertEqual(byTime.count, byIndex.count, "\(sourceRate) fps at \(rate): count")
                for (tick, pair) in zip(byTime, byIndex).enumerated() {
                    XCTAssertLessThanOrEqual(abs(pair.0 - pair.1), 1, "\(sourceRate) fps at \(rate), tick \(tick)")
                }
                if sourceRate == 30 { XCTAssertEqual(byTime, byIndex, "30 fps (the PRD's reference rate) must match exactly") }
            }
        }
    }

    // MARK: - Loop selection

    func testLoopMinimumDurationIsHonouredInSecondsOnAVariableRateClip() throws {
        // 40 frames: the first 20 at 30 fps (0.667 s), then 20 at 5 fps (4 s). A frame-counting
        // search at the nominal 30 fps thinks 30 frames is 1 s; in real time the first 30 frames
        // are 0.667 + 10 * 0.2 = 2.67 s. Make the only good match too short in time but long in frames.
        var times = (0..<20).map { Double($0) / 30 }
        times += (0..<20).map { 20.0 / 30 + Double($0) * 0.2 }
        var signatures = (0..<40).map { LoopSelectionTests.flat(Float($0) / 40) }
        // Frames 0 and 12 match perfectly: 12 frames, but only 0.4 s at the front's fast rate.
        signatures[12] = signatures[0]
        let config = LoopSelectionConfig(windowFraction: 1.0, minimumDuration: 1.0, crossfadeFrames: 0)

        // Counting frames at 30 fps, 12 frames is under the 30-frame minimum anyway; use a 10 fps
        // nominal rate so the frame count (10) is met and only real time says it is too short.
        let nominal = try LoopSelector.select(signatures: signatures, frameRate: 10, mode: .loop, config: config)
        guard case .selected(let byCount) = nominal else { return XCTFail("expected a loop") }
        XCTAssertEqual(byCount.startIndex, 0)
        XCTAssertEqual(byCount.returnIndex, 12, "by frame count the 12-frame loop is long enough")

        let real = try LoopSelector.select(signatures: signatures, frameRate: 10, mode: .loop, config: config, frameTimes: times)
        guard case .selected(let byTime) = real else { return XCTFail("expected a loop") }
        let playing = times[byTime.returnIndex] - times[byTime.startIndex]
        XCTAssertGreaterThanOrEqual(playing, 1.0 - 1e-6, "the loop must last at least a second of REAL time, lasts \(playing)")
        XCTAssertNotEqual(byTime.returnIndex, 12)
    }

    func testEvenlySpacedFrameTimesDoNotChangeLoopSelection() async throws {
        for fixture in ["periodic", "combined"] {
            let (signatures, frameRate) = try await LoopSelectionTests.signatures(fixture: fixture, stabilized: false)
            let times = (0..<signatures.count).map { Double($0) / frameRate }
            let without = try LoopSelector.select(signatures: signatures, frameRate: frameRate, mode: .loop)
            let with = try LoopSelector.select(signatures: signatures, frameRate: frameRate, mode: .loop, frameTimes: times)
            XCTAssertEqual(without, with, "\(fixture)")
        }
    }

    // MARK: - MP4 keeps the source's presentation times

    func testExportedMP4HasTheSourcesPresentationTimes() async throws {
        try XCTSkipUnless(VideoEncoder.isHEVCEncoderAvailable(), "no HEVC encoder on this machine")
        let source = try Self.makeClip(times: Self.irregularTimes)
        defer { try? FileManager.default.removeItem(at: source) }
        let path = Self.identityPath(frameCount: Self.irregularTimes.count, size: CGSize(width: 64, height: 64))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await ClipExporter.exportVideo(movieURL: source, path: path, preset: .small, mode: .once, to: url)
        XCTAssertEqual(result.frameCount, Self.irregularTimes.count)

        let written = try await Self.sampleTimes(of: url)
        XCTAssertEqual(written.count, Self.irregularTimes.count)
        let expected = FrameTiming.relative(Self.irregularTimes)
        for (i, (got, want)) in zip(written, expected).enumerated() {
            XCTAssertEqual(got, want, accuracy: 1e-4, "sample \(i): wrote \(got) s, source was at \(want) s")
        }
    }

    func testBounceReplaysTheSourceGapsBackwards() async throws {
        try XCTSkipUnless(VideoEncoder.isHEVCEncoderAvailable(), "no HEVC encoder on this machine")
        let times = [0.0, 0.1, 0.5, 0.6] // gaps 0.1, 0.4, 0.1
        let source = try Self.makeClip(times: times)
        defer { try? FileManager.default.removeItem(at: source) }
        let path = Self.identityPath(frameCount: times.count, size: CGSize(width: 64, height: 64))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await ClipExporter.exportVideo(movieURL: source, path: path, preset: .small, mode: .bounce, to: url)
        let written = try await Self.sampleTimes(of: url)
        // Forward 0, 0.1, 0.5, 0.6. Then back over the same gaps, last first: frame 2 follows frame 3
        // by the 0.1 s between them (0.7), frame 1 by the 0.4 s gap (1.1), frame 0 by 0.1 s (1.2).
        let expected = [0.0, 0.1, 0.5, 0.6, 0.7, 1.1, 1.2]
        XCTAssertEqual(written.count, expected.count)
        for (i, (got, want)) in zip(written, expected).enumerated() {
            XCTAssertEqual(got, want, accuracy: 1e-4, "sample \(i)")
        }
    }

    func testConstantRateFixtureExportKeepsEvenTimestamps() async throws {
        try XCTSkipUnless(VideoEncoder.isHEVCEncoderAvailable(), "no HEVC encoder on this machine")
        let movie = CameraPathTests.fixturesDirectory.appendingPathComponent("translate-shake.mov")
        let (motion, size) = try CameraPathTests.motion(fixture: "translate-shake")
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await ClipExporter.exportVideo(movieURL: movie, path: path, preset: .small, mode: .once, to: url)
        let written = try await Self.sampleTimes(of: url)
        XCTAssertEqual(written.count, 90)
        for (i, got) in written.enumerated() {
            XCTAssertEqual(got, Double(i) / 30, accuracy: 1e-6, "sample \(i)")
        }
    }

    // MARK: - Helpers

    static func identityPath(frameCount: Int, size: CGSize) -> CameraPath {
        CameraPath(
            corrections: Array(repeating: matrix_identity_float3x3, count: frameCount),
            crop: CGRect(origin: .zero, size: size), cropRetention: 1
        )
    }

    /// Presentation time of every sample in a movie file, in seconds, in presentation order.
    static func sampleTimes(of url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        return times.sorted()
    }

    /// A small movie whose frames are stamped at exactly `times` (seconds, on a 1/600 grid).
    static func makeClip(times: [Double], size: CGSize = CGSize(width: 64, height: 64)) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        for (index, time) in times.enumerated() {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            guard let pool = adaptor.pixelBufferPool else { throw CocoaError(.fileWriteUnknown) }
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            let shade = Double(index) / Double(max(times.count - 1, 1))
            context.render(
                CIImage(color: CIColor(red: shade, green: 1 - shade, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: size)),
                to: out!, bounds: CGRect(origin: .zero, size: size), colorSpace: nil
            )
            let stamp = CMTime(value: CMTimeValue((time * 600).rounded()), timescale: 600)
            guard adaptor.append(out!, withPresentationTime: stamp) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}
