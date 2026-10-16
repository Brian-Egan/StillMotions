import CoreImage
import CoreVideo
import XCTest
import simd
@testable import HarnessCLI
@testable import StillMotionsPipeline

/// #19: subject masking. The Vision-backed tests use Vision segmentation, which works on hosted
/// runners; the ones that use optical flow skip where flow is unavailable.
final class MaskingTests: XCTestCase {
    // MARK: - SubjectMask and the 60% rule (no Vision)

    func testCoverageUnionAndEmptyFull() {
        XCTAssertEqual(SubjectMask.empty.coverage, 0)
        XCTAssertTrue(SubjectMask.empty.isEmpty)
        XCTAssertEqual(SubjectMask.full.coverage, 1)
        XCTAssertFalse(SubjectMask.full.isEmpty)

        var left = [UInt8](repeating: 0, count: SubjectMask.gridWidth * SubjectMask.gridHeight)
        var right = left
        for y in 0..<SubjectMask.gridHeight {
            for x in 0..<(SubjectMask.gridWidth / 4) { left[y * SubjectMask.gridWidth + x] = 1 }
            for x in (SubjectMask.gridWidth / 2)..<(SubjectMask.gridWidth * 3 / 4) { right[y * SubjectMask.gridWidth + x] = 1 }
        }
        let union = SubjectMask(cells: left).union(SubjectMask(cells: right))
        XCTAssertEqual(union.coverage, 0.5, accuracy: 0.001)
        XCTAssertTrue(union.contains(nx: 0.1, ny: 0.5))
        XCTAssertFalse(union.contains(nx: 0.4, ny: 0.5))
        XCTAssertTrue(union.contains(nx: 0.6, ny: 0.5))
    }

    func testDilationGrowsTheMaskByTheRadius() {
        var cells = [UInt8](repeating: 0, count: SubjectMask.gridWidth * SubjectMask.gridHeight)
        cells[100 * SubjectMask.gridWidth + 200] = 1
        let grown = SubjectMask.dilated(rawCells: cells, radius: 8)
        XCTAssertEqual(grown.cells.reduce(0) { $0 + Int($1) }, 17 * 17, "a single cell grows to a 17x17 square")
    }

    func testBlankingPaintsOnlyMaskedPixelsGrey() throws {
        let width = 96, height = 54
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &out)
        let buffer = out!
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer)!, 255, CVPixelBufferGetBytesPerRow(buffer) * height) // white
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var cells = [UInt8](repeating: 0, count: SubjectMask.gridWidth * SubjectMask.gridHeight)
        for y in 0..<SubjectMask.gridHeight { for x in 0..<(SubjectMask.gridWidth / 2) { cells[y * SubjectMask.gridWidth + x] = 1 } }
        let blanked = try SubjectMask(cells: cells).blanking(buffer)

        CVPixelBufferLockBaseAddress(blanked, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(blanked, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(blanked)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(blanked)
        XCTAssertEqual(base[10 * 4 + 0 + 20 * stride], 128, "left half is masked, painted mid-grey")
        XCTAssertEqual(base[80 * 4 + 0 + 20 * stride], 255, "right half is untouched")
        XCTAssertEqual(base[10 * 4 + 3 + 20 * stride], 255, "alpha is kept")
    }

    /// PRD R-6 / #19: past 60% coverage the mask is dropped, not applied.
    func testASubjectCoveringMoreThanSixtyPercentIsSkipped() {
        let everything = SubjectMasker.apply(skipRule: 0.6, to: .full)
        XCTAssertTrue(everything.skipped)
        XCTAssertTrue(everything.mask.isEmpty, "a skipped mask is empty, so nothing is excluded")
        XCTAssertEqual(everything.rawCoverage, 1)

        // Exactly 61% of rows masked.
        var cells = [UInt8](repeating: 0, count: SubjectMask.gridWidth * SubjectMask.gridHeight)
        let rows = Int((Double(SubjectMask.gridHeight) * 0.61).rounded(.up))
        for y in 0..<rows { for x in 0..<SubjectMask.gridWidth { cells[y * SubjectMask.gridWidth + x] = 1 } }
        let over = SubjectMask(cells: cells)
        XCTAssertGreaterThan(over.coverage, 0.6)
        XCTAssertTrue(SubjectMasker.apply(skipRule: 0.6, to: over).skipped)

        // Just under: kept as is.
        let underRows = Int((Double(SubjectMask.gridHeight) * 0.59).rounded(.down))
        var underCells = [UInt8](repeating: 0, count: SubjectMask.gridWidth * SubjectMask.gridHeight)
        for y in 0..<underRows { for x in 0..<SubjectMask.gridWidth { underCells[y * SubjectMask.gridWidth + x] = 1 } }
        let under = SubjectMasker.apply(skipRule: 0.6, to: SubjectMask(cells: underCells))
        XCTAssertFalse(under.skipped)
        XCTAssertEqual(under.mask, SubjectMask(cells: underCells))

        // Configurable: the same 61% mask is kept when the threshold is 0.8.
        XCTAssertFalse(SubjectMasker.apply(skipRule: 0.8, to: over).skipped)
        XCTAssertEqual(SubjectMasker.Configuration().maxCoverage, 0.6, "the default is the PRD's 60%")
    }

    // MARK: - Vision masks on a moving subject

    private static func largeSubject() throws -> BenchmarkEstimators.Scenario {
        let truth = try FixtureTruth.load(from: MotionEstimationTests.fixturesDirectory.appendingPathComponent("moving-subject.truth.json"))
        return try BenchmarkEstimators.largeSubjectScenario(movingSubjectTruth: truth, context: CIContext())
    }

    /// The committed `moving-subject` clip's subject covers under 1% of the frame, too small for
    /// either estimator to notice (Vision finds nothing there), so the "masking lowers the error"
    /// criterion is measured on the in-memory large-subject variant, as in #10.
    func testMaskingLowersRegistrationErrorWithALargeMovingSubject() async throws {
        let scenario = try Self.largeSubject()
        let indices = [0, 20, 40, 60, 80]
        let frames = try await scenario.loadFrames(indices)
        let reference = frames[0]!
        let truth = scenario.truth
        let size = CGSize(width: truth.width, height: truth.height)
        let masker = SubjectMasker()
        let estimator = VisionRegistrationEstimator()

        let referenceMask = try await masker.mask(for: reference)
        XCTAssertFalse(referenceMask.skipped)
        XCTAssertGreaterThan(referenceMask.rawCoverage, 0.1, "Vision should find the large subject")

        var unmasked: [Double] = [], masked: [Double] = []
        let referenceInverse = truth.frames[0].matrix.inverse
        for index in indices.dropFirst() {
            let frame = frames[index]!
            let want = truth.frames[index].matrix * referenceInverse

            unmasked.append(MotionEstimationTests.rms(
                recovered: try await estimator.estimate(frame: frame, reference: reference).transform, truth: want, frameSize: size
            ))

            let frameMask = try await masker.mask(for: frame)
            let both = frameMask.mask.union(referenceMask.mask)
            let motion = try await estimator.estimate(frame: try both.blanking(frame), reference: try both.blanking(reference))
            masked.append(MotionEstimationTests.rms(recovered: motion.transform, truth: want, frameSize: size))
        }
        let meanUnmasked = unmasked.reduce(0, +) / Double(unmasked.count)
        let meanMasked = masked.reduce(0, +) / Double(masked.count)
        print("\n=== moving-subject-large, registration: unmasked \(String(format: "%.3f", meanUnmasked)) px, masked \(String(format: "%.3f", meanMasked)) px ===")
        XCTAssertLessThan(meanMasked, meanUnmasked, "masking must lower the transform error when a subject moves")
    }

    func testMaskingDropsSubjectSamplesFromFlowAndRaisesTheInlierRatio() async throws {
        let flowAvailable = await FlowAvailability.probe()
        try XCTSkipUnless(flowAvailable, "Vision optical flow is unavailable on this machine")
        let scenario = try Self.largeSubject()
        let frames = try await scenario.loadFrames([0, 60])
        let masker = SubjectMasker()
        let flow = OpticalFlowEstimator()

        let plain = try await flow.estimateWithEvidence(frame: frames[60]!, reference: frames[0]!)
        let referenceMask = try await masker.mask(for: frames[0]!)
        let frameMask = try await masker.mask(for: frames[60]!)
        let withMasks = try await flow.estimateWithEvidence(
            frame: frames[60]!, reference: frames[0]!, frameMask: frameMask.mask, referenceMask: referenceMask.mask
        )

        XCTAssertLessThan(withMasks.motion.correspondences.count, plain.motion.correspondences.count, "samples on the subject are dropped")
        XCTAssertGreaterThan(try XCTUnwrap(withMasks.motion.inlierRatio), try XCTUnwrap(plain.motion.inlierRatio), "what is left agrees better")
        print("\n=== flow on moving-subject-large: inlierRatio \(String(format: "%.2f", plain.motion.inlierRatio ?? 0)) -> \(String(format: "%.2f", withMasks.motion.inlierRatio ?? 0)) with masks; \(plain.motion.correspondences.count) -> \(withMasks.motion.correspondences.count) samples ===")
    }

    // MARK: - No regression where there is no subject

    func testMaskingDoesNotMakeSubjectFreeFixturesWorse() async throws {
        let masker = SubjectMasker()
        let estimator = VisionRegistrationEstimator()
        var table = "fixture,unmaskedRMS,maskedRMS,framesMasked\n"
        for fixture in MotionEstimationTests.accuracyFixtures {
            let indices = [0] + [20, 40, 60, 80]
            let frames = try await MotionEstimationTests.loadFrames(fixture: fixture, indices: indices)
            let truth = try FixtureTruth.load(from: MotionEstimationTests.fixturesDirectory.appendingPathComponent("\(fixture).truth.json"))
            let size = CGSize(width: truth.width, height: truth.height)
            let reference = frames[0].pixelBuffer
            let referenceMask = try await masker.mask(for: reference)
            let referenceInverse = truth.frames[0].matrix.inverse

            var unmasked: [Double] = [], masked: [Double] = []
            var framesMasked = referenceMask.mask.isEmpty ? 0 : 1
            for loaded in frames.dropFirst() {
                let want = truth.frames[loaded.index].matrix * referenceInverse
                unmasked.append(MotionEstimationTests.rms(
                    recovered: try await estimator.estimate(frame: loaded.pixelBuffer, reference: reference).transform, truth: want, frameSize: size
                ))
                let frameMask = try await masker.mask(for: loaded.pixelBuffer)
                if !frameMask.mask.isEmpty { framesMasked += 1 }
                let both = frameMask.mask.union(referenceMask.mask)
                let motion = both.isEmpty
                    ? try await estimator.estimate(frame: loaded.pixelBuffer, reference: reference)
                    : try await estimator.estimate(frame: try both.blanking(loaded.pixelBuffer), reference: try both.blanking(reference))
                masked.append(MotionEstimationTests.rms(recovered: motion.transform, truth: want, frameSize: size))
            }
            let u = unmasked.reduce(0, +) / Double(unmasked.count), m = masked.reduce(0, +) / Double(masked.count)
            table += "\(fixture),\(String(format: "%.3f", u)),\(String(format: "%.3f", m)),\(framesMasked)\n"
            // 0.05 px is well inside the 0.75 px accuracy bar and above the run-to-run noise of
            // blanking a few pixels; a real regression would be many times that.
            XCTAssertLessThanOrEqual(m, u + 0.05, "\(fixture): masking made the estimate worse (\(u) -> \(m) px)")
        }
        print("\n=== subject-free fixtures, registration RMS (px) ===\n\(table)")
    }

    // MARK: - Cost

    func testRecordsMaskingCostAt720AndNative() async throws {
        let frames = try await MotionEstimationTests.loadFrames(fixture: "combined", indices: [0])
        let native = frames[0].pixelBuffer
        let small = try SpikeBuffers.scaled(native, longEdge: 720, context: CIContext()).buffer
        let masker = SubjectMasker()
        _ = try await masker.mask(for: small) // first call loads the models
        for (label, buffer) in [("720", small), ("native 1920", native)] {
            let start = DispatchTime.now()
            let runs = 5
            for _ in 0..<runs { _ = try await masker.mask(for: buffer) }
            let ms = SpikeFlowEstimator.milliseconds(since: start) / Double(runs)
            print("masking cost, \(label) input: \(String(format: "%.1f", ms)) ms/frame (Mac, relative signal only)")
        }
    }
}
