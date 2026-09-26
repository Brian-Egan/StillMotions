import AVFoundation
import XCTest
@testable import StillMotionsPipeline

/// PRD R-21 acceptance: a test reads a sidecar and asserts its frame count matches the
/// clip — the sidecar is only useful as ground truth if it actually describes the file
/// next to it.
final class FixtureTruthTests: XCTestCase {
    static let fixtureNames = [
        "translate-linear", "translate-shake", "rotate", "scale",
        "combined", "periodic", "moving-subject", "parallax",
    ]

    static let fixturesDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // PipelineTests
            .deletingLastPathComponent() // tests
            .appendingPathComponent("fixtures/synthetic", isDirectory: true)
    }()

    func testSidecarFrameCountMatchesClip() async throws {
        for name in Self.fixtureNames {
            let truthURL = Self.fixturesDirectory.appendingPathComponent("\(name).truth.json")
            let movURL = Self.fixturesDirectory.appendingPathComponent("\(name).mov")

            let truth = try FixtureTruth.load(from: truthURL)
            XCTAssertEqual(truth.frames.count, truth.frameCount, "\(name): sidecar's frame array disagrees with its own frameCount")

            let asset = AVURLAsset(url: movURL)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                XCTFail("\(name): no video track")
                continue
            }
            let frameCount = try await countFrames(track: track)
            XCTAssertEqual(frameCount, truth.frameCount, "\(name): clip has \(frameCount) frames, sidecar claims \(truth.frameCount)")
        }
    }

    func testEachFrameTruthHasAWellFormedTransform() throws {
        for name in Self.fixtureNames {
            let truth = try FixtureTruth.load(from: Self.fixturesDirectory.appendingPathComponent("\(name).truth.json"))
            for frame in truth.frames {
                XCTAssertEqual(frame.transform.count, 3, "\(name) frame \(frame.index): transform must have 3 rows")
                for row in frame.transform {
                    XCTAssertEqual(row.count, 3, "\(name) frame \(frame.index): each row must have 3 columns")
                }
                XCTAssertEqual(frame.transform[2], [0, 0, 1], "\(name) frame \(frame.index): bottom row must be affine, not projective")
            }
        }
    }

    /// Decodes to pixel buffers rather than reading compressed samples: the same path the
    /// real streaming decoder (#8) will use, and the one that agrees with `ffprobe
    /// -count_frames`. Compressed passthrough (`outputSettings: nil`) reports a few extra
    /// boundary sample buffers on this toolchain that are not decodable frames.
    private func countFrames(track: AVAssetTrack) async throws -> Int {
        let asset = track.asset!
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        reader.startReading()
        var count = 0
        while output.copyNextSampleBuffer() != nil {
            count += 1
        }
        return count
    }
}
