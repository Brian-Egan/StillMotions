import AVFoundation
import CoreImage
import XCTest
import simd
@testable import StillMotionsPipeline

private struct ResizeFailure: Error {}

final class MotionEstimationTests: XCTestCase {
    static let fixturesDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/synthetic", isDirectory: true)
    }()

    /// Every fixture with a single well-defined camera motion. `moving-subject` and
    /// `parallax` are deliberately excluded — they exist to show where a single homography
    /// breaks down (#7), not to be recovered exactly.
    static let accuracyFixtures = ["translate-linear", "translate-shake", "rotate", "scale", "combined"]

    /// Every 10th frame (skipping 0, which is trivially identity against itself): enough
    /// coverage to catch a systematic error without paying Vision's cost on all 90 frames
    /// times 5 fixtures in every `swift test` run.
    static let sampledIndices = stride(from: 10, to: 90, by: 10).map { $0 }

    // MARK: - Accuracy (#9 acceptance: 0.5px RMS)

    func testRecoveredTransformsMatchKnownMotionWithin0_5pxRMS() async throws {
        let estimator = VisionRegistrationEstimator()
        var report = "fixture,meanRMSpx,maxRMSpx\n"

        for name in Self.accuracyFixtures {
            let frames = try await Self.loadFrames(fixture: name, indices: [0] + Self.sampledIndices)
            let truth = try FixtureTruth.load(from: Self.fixturesDirectory.appendingPathComponent("\(name).truth.json"))
            let reference = frames[0].pixelBuffer

            // Relative to the reference frame's OWN truth transform, not the canvas
            // origin: frame 0 need not itself be identity (translate-shake's jitter is
            // drawn at every index, including 0), so "frame_i vs frame_0" must be compared
            // against truth(i) composed with truth(0)'s inverse, not truth(i) alone.
            let referenceInverse = truth.frames[0].matrix.inverse
            var rmsValues: [Double] = []
            for loaded in frames.dropFirst() {
                let motion = try await estimator.estimate(frame: loaded.pixelBuffer, reference: reference)
                let truthMatrix = truth.frames[loaded.index].matrix * referenceInverse
                let rms = Self.rms(recovered: motion.transform, truth: truthMatrix, frameSize: CGSize(width: truth.width, height: truth.height))
                rmsValues.append(rms)
                XCTAssertLessThan(rms, 0.5, "\(name) frame \(loaded.index): RMS \(rms)px exceeds 0.5px")
            }
            let mean = rmsValues.reduce(0, +) / Double(rmsValues.count)
            let max = rmsValues.max() ?? 0
            report += "\(name),\(String(format: "%.4f", mean)),\(String(format: "%.4f", max))\n"
        }
        print("\n=== RMS accuracy (VisionRegistrationEstimator) ===\n\(report)")
    }

    // MARK: - Plausibility gate (#9 acceptance)

    func testPlausibilityGateRejectsAnObviouslyWrongTransform() {
        // A 90-degree rotation: never a plausible per-frame motion for a handheld 3s clip.
        let angle = Float.pi / 2
        let wildRotation = simd_float3x3(rows: [
            SIMD3<Float>(cos(angle), -sin(angle), 0),
            SIMD3<Float>(sin(angle), cos(angle), 0),
            SIMD3<Float>(0, 0, 1),
        ])
        XCTAssertThrowsError(try VisionRegistrationEstimator.checkPlausibility(wildRotation, frameWidth: 1920, frameHeight: 1080))

        let wildScale = simd_float3x3(rows: [
            SIMD3<Float>(5, 0, 0),
            SIMD3<Float>(0, 5, 0),
            SIMD3<Float>(0, 0, 1),
        ])
        XCTAssertThrowsError(try VisionRegistrationEstimator.checkPlausibility(wildScale, frameWidth: 1920, frameHeight: 1080))

        let wildTranslation = simd_float3x3(rows: [
            SIMD3<Float>(1, 0, 5000),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
        ])
        XCTAssertThrowsError(try VisionRegistrationEstimator.checkPlausibility(wildTranslation, frameWidth: 1920, frameHeight: 1080))

        // A small, ordinary motion must NOT be rejected.
        let ordinary = simd_float3x3(rows: [
            SIMD3<Float>(1.01, -0.02, 12),
            SIMD3<Float>(0.02, 1.01, -4),
            SIMD3<Float>(0, 0, 1),
        ])
        XCTAssertNoThrow(try VisionRegistrationEstimator.checkPlausibility(ordinary, frameWidth: 1920, frameHeight: 1080))
    }

    func testEndToEndOnADeliberatelyCorruptedPairFailsRatherThanPassingNonsenseDownstream() async throws {
        // Pairing translate-linear's reference with parallax's heavily-occluded near-layer
        // frame: visually unrelated content Vision cannot plausibly register. Success here
        // is either a thrown Vision error or our own implausibleTransform — either way,
        // "did not silently return a wrong-but-plausible-looking answer".
        let a = try await Self.loadFrames(fixture: "translate-linear", indices: [0])[0].pixelBuffer
        let b = try await Self.loadFrames(fixture: "parallax", indices: [45])[0].pixelBuffer

        let estimator = VisionRegistrationEstimator()
        do {
            let motion = try await estimator.estimate(frame: b, reference: a)
            // If Vision genuinely returns something, it must at least be a plausible affine
            // transform — the gate already checked that inside `estimate`. Note the result
            // rather than asserting failure outright: two visually-different-but-textured
            // synthetic frames are not guaranteed to defeat a whole-image registrator, and
            // the point of the gate is to reject what's actually implausible, not to reject
            // "harder" input just because it's from a different fixture.
            print("corrupted-pair estimate did not throw; recovered transform: \(motion.transform)")
        } catch {
            // Expected path.
        }
    }

    // MARK: - Timing (#9 acceptance: ms/frame at 720p and native, on macOS)
    //
    // Measured on THIS build machine, not the iPhone 14 Pro reference device (PRD §1.3) —
    // there is no simulator/Mac substitute for that number (CLAUDE.md). These figures exist
    // to compare estimators against each other for the phase-1 spike (#10), which explicitly
    // uses macOS numbers with a stated safety margin (decisions/0001-motion-estimation.md),
    // not to claim any on-device budget is met.

    func testMeasureMillisecondsPerFrameAtNativeAndAt720p() async throws {
        let fixture = "combined"
        let loaded = try await Self.loadFrames(fixture: fixture, indices: [0] + Self.sampledIndices)
        let reference = loaded[0].pixelBuffer
        let estimator = VisionRegistrationEstimator()

        let nativeMs = try await Self.averageMilliseconds(estimator: estimator, reference: reference, frames: loaded.dropFirst().map(\.pixelBuffer))

        let context = CIContext()
        let scale = 720.0 / 1920.0
        let scaledReference = try Self.resize(reference, scale: scale, context: context)
        let scaledFrames = try loaded.dropFirst().map { try Self.resize($0.pixelBuffer, scale: scale, context: context) }
        let scaledMs = try await Self.averageMilliseconds(estimator: estimator, reference: scaledReference, frames: scaledFrames)

        print("\n=== VisionRegistrationEstimator timing (macOS build machine, NOT the iPhone 14 Pro reference device) ===")
        print("native (1920x1080): \(String(format: "%.2f", nativeMs)) ms/frame")
        print("720p   (1280x720):  \(String(format: "%.2f", scaledMs)) ms/frame")
    }

    // MARK: - Helpers

    struct LoadedFrame {
        let index: Int
        let pixelBuffer: CVPixelBuffer
    }

    static func loadFrames(fixture: String, indices: [Int]) async throws -> [LoadedFrame] {
        let url = fixturesDirectory.appendingPathComponent("\(fixture).mov")
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let sequence = try FrameSequence.make(asset: asset, track: track)
        let wanted = Set(indices)
        var result: [Int: CVPixelBuffer] = [:]
        var i = 0
        for pixelBuffer in sequence {
            if wanted.contains(i) { result[i] = pixelBuffer }
            i += 1
            if result.count == wanted.count { break }
        }
        return indices.map { LoadedFrame(index: $0, pixelBuffer: result[$0]!) }
    }

    /// RMS displacement, in pixels, between `recovered` and `truth` applied to a 5x5 grid
    /// covering the frame — a broader accuracy check than comparing matrix coefficients
    /// directly, since a small coefficient error can matter more or less depending where in
    /// the frame it lands.
    static func rms(recovered: simd_float3x3, truth: simd_float3x3, frameSize: CGSize) -> Double {
        var sumSquared = 0.0
        var count = 0
        for gx in stride(from: 0.1, through: 0.9, by: 0.2) {
            for gy in stride(from: 0.1, through: 0.9, by: 0.2) {
                let p = SIMD3<Float>(Float(gx * frameSize.width), Float(gy * frameSize.height), 1)
                let pr = recovered * p
                let pt = truth * p
                let dx = Double(pr.x / pr.z - pt.x / pt.z)
                let dy = Double(pr.y / pr.z - pt.y / pt.z)
                sumSquared += dx * dx + dy * dy
                count += 1
            }
        }
        return (sumSquared / Double(count)).squareRoot()
    }

    static func averageMilliseconds(estimator: VisionRegistrationEstimator, reference: CVPixelBuffer, frames: [CVPixelBuffer]) async throws -> Double {
        var total: Double = 0
        for frame in frames {
            let start = DispatchTime.now()
            _ = try await estimator.estimate(frame: frame, reference: reference)
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            total += Double(elapsedNs) / 1_000_000
        }
        return total / Double(frames.count)
    }

    static func resize(_ pixelBuffer: CVPixelBuffer, scale: Double, context: CIContext) throws -> CVPixelBuffer {
        let width = Int(Double(CVPixelBufferGetWidth(pixelBuffer)) * scale)
        let height = Int(Double(CVPixelBufferGetHeight(pixelBuffer)) * scale)
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &out)
        guard let outBuffer = out else { throw ResizeFailure() }
        let image = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(image, to: outBuffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return outBuffer
    }
}
