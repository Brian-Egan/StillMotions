import AVFoundation
import CoreImage
import XCTest
import simd
@testable import StillMotionsPipeline

final class LoopSelectionTests: XCTestCase {
    // MARK: - Signatures from fixtures

    static let signatureWidth = 64
    static let signatureHeight = 36

    /// One signature per frame. `stabilized` applies the solver's corrections and crop first,
    /// which is what the pipeline feeds the selector. Raw frames are used only where the clip's
    /// own camera motion is the signal under test (see the periodic test).
    static func signatures(fixture: String, stabilized: Bool) async throws -> (signatures: [FrameSignature], frameRate: Double) {
        let (motion, size) = try CameraPathTests.motion(fixture: fixture)
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
        let url = CameraPathTests.fixturesDirectory.appendingPathComponent("\(fixture).mov")
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let frameRate = Double(try await track.load(.nominalFrameRate))
        let context = CIContext()

        var result: [FrameSignature] = []
        var index = 0
        for pixelBuffer in try FrameSequence.make(asset: asset, track: track) {
            var image = CIImage(cvPixelBuffer: pixelBuffer)
            var region = CGRect(origin: .zero, size: size)
            if stabilized {
                let m = path.corrections[index]
                let correction = CGAffineTransform(
                    a: CGFloat(m[0][0]), b: CGFloat(m[0][1]), c: CGFloat(m[1][0]),
                    d: CGFloat(m[1][1]), tx: CGFloat(m[2][0]), ty: CGFloat(m[2][1])
                )
                image = image.transformed(by: correction)
                region = path.crop
            }
            let scale = CGFloat(signatureWidth) / region.width
            let small = image.cropped(to: region)
                .transformed(by: CGAffineTransform(translationX: -region.minX, y: -region.minY))
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            result.append(try luma(of: small, context: context))
            index += 1
        }
        return (result, frameRate)
    }

    static func luma(of image: CIImage, context: CIContext) throws -> FrameSignature {
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, signatureWidth, signatureHeight, kCVPixelFormatType_32BGRA, nil, &out)
        let buffer = try XCTUnwrap(out)
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: signatureWidth, height: signatureHeight), colorSpace: nil)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var luma: [Float] = []
        for y in 0..<signatureHeight {
            for x in 0..<signatureWidth {
                let p = base + y * stride + x * 4 // B, G, R, A
                luma.append((0.114 * Float(p[0]) + 0.587 * Float(p[1]) + 0.299 * Float(p[2])) / 255)
            }
        }
        return FrameSignature(luma: luma)
    }

    /// A flat picture of one brightness: the simplest signature, for algorithm tests.
    static func flat(_ value: Float) -> FrameSignature {
        FrameSignature(luma: [Float](repeating: value, count: 16))
    }

    func selection(_ outcome: LoopOutcome, file: StaticString = #filePath, line: UInt = #line) throws -> LoopSelection {
        guard case .selected(let selection) = outcome else {
            XCTFail("expected a selected loop, got \(outcome)", file: file, line: line)
            throw XCTSkip("no selection")
        }
        return selection
    }

    // MARK: - Period

    func testPeriodicFixtureLoopLengthIsItsPeriod() async throws {
        // `periodic` moves its camera with an exact 45-frame period. Stabilizing removes that
        // motion entirely (every stabilized frame is the same picture), leaving nothing to
        // find a period in. So this uses the RAW frames: it tests the search, not the
        // stabilizer. Stabilized seam quality is covered below.
        let (signatures, frameRate) = try await Self.signatures(fixture: "periodic", stabilized: false)
        let chosen = try selection(LoopSelector.select(signatures: signatures, frameRate: frameRate, mode: .loop))

        print("periodic: start \(chosen.startIndex) return \(chosen.returnIndex) length \(chosen.length) seam \(chosen.seamRatio) (before crossfade \(chosen.seamRatioBeforeCrossfade))")
        XCTAssertEqual(Double(chosen.length), 45, accuracy: 1)
        XCTAssertLessThanOrEqual(chosen.seamRatio, 1.5)
    }

    // MARK: - Seam metric on stabilized clips

    func testSeamIsWithinOnePointFiveTimesTheMedianOnStabilizedFixtures() async throws {
        for fixture in ["translate-shake", "rotate", "periodic"] {
            let (signatures, frameRate) = try await Self.signatures(fixture: fixture, stabilized: true)
            let chosen = try selection(LoopSelector.select(signatures: signatures, frameRate: frameRate, mode: .loop))
            print("\(fixture) (stabilized): length \(chosen.length), start \(chosen.startIndex), seam ratio \(String(format: "%.3f", chosen.seamRatio)), before crossfade \(String(format: "%.3f", chosen.seamRatioBeforeCrossfade)), median step \(String(format: "%.5f", chosen.medianStep))")
            XCTAssertLessThanOrEqual(chosen.seamRatio, 1.5, fixture)
            XCTAssertGreaterThanOrEqual(chosen.length, Int(frameRate), "\(fixture): below the 1 s floor")
        }
    }

    // MARK: - Minimum duration

    func testMinimumDurationFloorRejectsADegenerateShortLoop() throws {
        // Frames 20 and 22 are identical and every other frame is distinct, so a 2-frame loop
        // is the "perfect" match. The floor must stop it being chosen.
        var signatures = (0..<90).map { Self.flat(Float($0) / 90) }
        signatures[22] = signatures[20]
        let wholeClip = LoopSelectionConfig(windowFraction: 1.0, minimumDuration: 1.0, crossfadeFrames: 3)

        let floored = try selection(LoopSelector.select(signatures: signatures, frameRate: 30, mode: .loop, config: wholeClip))
        XCTAssertGreaterThanOrEqual(floored.length, 30)
        XCTAssertFalse(floored.startIndex == 20 && floored.returnIndex == 22)

        // Without the floor the degenerate loop does win, so the floor is what prevented it.
        let noFloor = LoopSelectionConfig(windowFraction: 1.0, minimumDuration: 0, crossfadeFrames: 3)
        let unfloored = try selection(LoopSelector.select(signatures: signatures, frameRate: 30, mode: .loop, config: noFloor))
        XCTAssertEqual(unfloored.length, 2)
    }

    // MARK: - Modes

    func testBounceAndOnceSkipTheSearchEntirely() throws {
        // Empty signatures would make the search throw, so getting `.skipped` back proves it
        // never ran.
        for mode in [PlaybackMode.bounce, .once] {
            XCTAssertEqual(try LoopSelector.select(signatures: [], frameRate: 30, mode: mode), .skipped(mode))
        }
        XCTAssertThrowsError(try LoopSelector.select(signatures: [], frameRate: 30, mode: .loop)) {
            XCTAssertEqual($0 as? LoopSelectionError, .tooFewFrames(0))
        }
    }

    // MARK: - Crossfade

    func testCrossfadeLowersTheSeamOnAClipThatDoesNotQuiteMatch() throws {
        // A steady brightness ramp: no two frames ever match, so the seam is a real jump.
        let ramp = (0..<90).map { Self.flat(Float($0) / 100) }
        let chosen = try selection(LoopSelector.select(signatures: ramp, frameRate: 30, mode: .loop))
        XCTAssertGreaterThan(chosen.seamRatioBeforeCrossfade, 5, "the test needs a clip with a visible seam")
        XCTAssertLessThan(chosen.seamRatio, chosen.seamRatioBeforeCrossfade)

        let off = LoopSelectionConfig(crossfadeFrames: 0)
        let plain = try selection(LoopSelector.select(signatures: ramp, frameRate: 30, mode: .loop, config: off))
        XCTAssertEqual(plain.seamRatio, plain.seamRatioBeforeCrossfade, accuracy: 1e-9)
    }

    func testCrossfadeNeverMakesTheSeamWorseOnStabilizedFootage() async throws {
        let (signatures, frameRate) = try await Self.signatures(fixture: "translate-shake", stabilized: true)
        let chosen = try selection(LoopSelector.select(signatures: signatures, frameRate: frameRate, mode: .loop))
        XCTAssertLessThanOrEqual(chosen.seamRatio, chosen.seamRatioBeforeCrossfade + 1e-6)
    }

    func testCrossfadeRecipeBlendsTheStartWithTheFootageAfterTheReturnFrame() throws {
        let signatures = (0..<90).map { Self.flat(Float($0) / 100) }
        let chosen = try selection(LoopSelector.select(signatures: signatures, frameRate: 30, mode: .loop))

        XCTAssertEqual(chosen.frames.count, chosen.length)
        let blended = chosen.frames.prefix(3)
        for (offset, recipe) in blended.enumerated() {
            XCTAssertEqual(recipe.primary, chosen.returnIndex + offset)
            XCTAssertEqual(recipe.secondary, chosen.startIndex + offset)
            XCTAssertEqual(recipe.secondaryWeight, Float(offset + 1) / 4, accuracy: 1e-6)
        }
        for (offset, recipe) in chosen.frames.enumerated().dropFirst(3) {
            XCTAssertEqual(recipe, LoopFrameRecipe(primary: chosen.startIndex + offset, secondary: nil, secondaryWeight: 0))
        }
    }

    // MARK: - Configuration

    func testCandidatesComeFromTheConfiguredWindows() throws {
        let signatures = (0..<100).map { Self.flat(sin(Float($0) * 0.7)) }
        for fraction in [0.1, 0.3, 0.5] {
            let config = LoopSelectionConfig(windowFraction: fraction, minimumDuration: 0.5)
            let chosen = try selection(LoopSelector.select(signatures: signatures, frameRate: 30, mode: .loop, config: config))
            let window = Int((100 * fraction).rounded(.up))
            XCTAssertLessThan(chosen.startIndex, window, "start outside the first \(fraction) of the clip")
            XCTAssertGreaterThanOrEqual(chosen.returnIndex, 100 - window, "return frame outside the last \(fraction) of the clip")
        }
    }

    func testVeryShortClipsStillGetAnAnswer() throws {
        let signatures = (0..<5).map { Self.flat(Float($0) / 10) }
        let chosen = try selection(LoopSelector.select(signatures: signatures, frameRate: 30, mode: .loop))
        XCTAssertGreaterThanOrEqual(chosen.length, 1)
        XCTAssertThrowsError(try LoopSelector.select(signatures: signatures, frameRate: 0, mode: .loop))
    }
}
