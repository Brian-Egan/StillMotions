import AVFoundation
import CoreImage
import Foundation
import StillMotionsPipeline
import Vision
import simd

/// `stillmotions-harness benchmark-estimators` — the measurement behind decision 0001 (#10).
///
/// Times and scores Vision registration against Vision optical flow (sampled and fit with
/// RANSAC) on the synthetic fixtures, where the camera path is known exactly, and compares
/// them on a moving-subject clip with and without masking.
///
/// Everything here runs on the build Mac. Those timings do NOT transfer to the iPhone 14
/// Pro (PRD §1.3); the decision record states the safety margin and defers confirmation to
/// the on-device verification issue (#26).
enum BenchmarkEstimators {
    // MARK: - Configuration

    /// Long-edge sizes measured by default; "native" means the clip's own resolution.
    static let defaultLongEdges = "720,native"
    static let accuracies: [(label: String, level: TrackOpticalFlowRequest.ComputationAccuracy)] = [
        ("low", .low), ("medium", .medium), ("high", .high), ("veryHigh", .veryHigh),
    ]
    /// Cameras with one well-defined motion. `parallax` is included for completeness but its
    /// truth is only the far layer, so no single transform is expected to match it exactly.
    static let fixtureNames = [
        "translate-linear", "translate-shake", "rotate", "scale", "combined", "periodic", "parallax",
    ]
    static let maskDilationCells = 8

    // MARK: - Scenarios

    /// One clip to measure: where its frames come from, the camera truth, and (for moving
    /// subject clips) a ground-truth mask of where the subject is.
    struct Scenario {
        let name: String
        let truth: FixtureTruth
        let loadFrames: ([Int]) async throws -> [Int: CVPixelBuffer]
        let oracleMask: ((Int) throws -> SubjectMask)?
    }

    struct Row: Codable {
        let scenario: String
        let estimator: String
        let accuracy: String
        let resolution: String
        let masking: String
        let frames: Int
        let failures: Int
        let warmupMs: Double
        let requestMsPerFrame: Double
        let sampleAndFitMsPerFrame: Double
        let totalMsPerFrame: Double
        let peakMemoryGrowthMB: Double
        let meanRMSpx: Double?
        let maxRMSpx: Double?
        let meanInlierRatio: Double?
        let meanMaskCoverage: Double?
        /// Flow only: Vision's flow scale for this size and level, and what measuring it cost
        /// (once per size and level, not per frame). Nil for registration.
        let flowScale: Double?
        let calibrationMs: Double?
    }

    struct Summary: Codable {
        let machine: String
        let os: String
        let frameIndices: [Int]
        let rows: [Row]
        /// Wall-clock for a 90-frame (3 s at 30 fps) clip at 720 px, per flow level:
        /// totalMsPerFrame x 90, on the scenario named in `extrapolationScenario`.
        let extrapolationScenario: String
        let threeSecondClipSecondsAt720: [String: Double]
    }

    // MARK: - Entry point

    static func run(arguments: [String]) async throws {
        guard let fixturesPath = FixtureGenerator.value(for: "--fixtures", in: arguments) else {
            throw FixtureGeneratorError.missingArgument("--fixtures")
        }
        guard let outPath = FixtureGenerator.value(for: "--out", in: arguments) else {
            throw FixtureGeneratorError.missingArgument("--out")
        }
        let stride = FixtureGenerator.value(for: "--stride", in: arguments).flatMap(Int.init) ?? 10
        let longEdges: [(label: String, value: Int?)] = (FixtureGenerator.value(for: "--long-edges", in: arguments) ?? defaultLongEdges)
            .split(separator: ",").map { $0 == "native" ? ("native", nil) : (String($0), Int($0)) }
        let only = FixtureGenerator.value(for: "--only", in: arguments).map { Set($0.split(separator: ",").map(String.init)) }
        let fixturesDir = URL(fileURLWithPath: fixturesPath, isDirectory: true)
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let indices = Swift.stride(from: stride, to: FixtureGenerator.frameCount, by: stride).map { $0 }
        var rows: [Row] = []
        let context = CIContext()
        // Flow scale per "resolution/accuracy", measured once and reused across scenarios.
        var calibrations: [String: (scale: Double, milliseconds: Double)] = [:]

        var scenarios: [Scenario] = []
        for name in fixtureNames where only?.contains(name) ?? true {
            scenarios.append(try fileScenario(name: name, in: fixturesDir))
        }
        if only?.contains("moving-subject") ?? true {
            scenarios.append(try fileScenario(name: "moving-subject", in: fixturesDir, withOracle: true))
        }
        if only?.contains("moving-subject-large") ?? true {
            scenarios.append(try largeSubjectScenario(movingSubjectTruth: try loadTruth("moving-subject", in: fixturesDir), context: context))
        }

        for scenario in scenarios {
            let isSubject = scenario.oracleMask != nil
            print("== \(scenario.name)")
            let frames = try await scenario.loadFrames([0] + indices)
            guard let reference = frames[0] else { throw SpikeError("no reference frame for \(scenario.name)") }

            // Masks are computed once per scenario and shared by every config.
            var visionMasks: [Int: SubjectMask] = [:]
            var oracleMasks: [Int: SubjectMask] = [:]
            if isSubject {
                for index in [0] + indices {
                    visionMasks[index] = try await visionForegroundMask(frames[index]!, context: context)
                    oracleMasks[index] = try scenario.oracleMask!(index)
                }
                let v = visionMasks.values.map(\.coverage).reduce(0, +) / Double(visionMasks.count)
                let o = oracleMasks.values.map(\.coverage).reduce(0, +) / Double(oracleMasks.count)
                print(String(format: "   mask coverage: vision %.1f%%, oracle %.1f%% (after dilation)", v * 100, o * 100))
            }
            let maskings: [(label: String, masks: [Int: SubjectMask]?)] = isSubject
                ? [("none", nil), ("vision", visionMasks), ("oracle", oracleMasks)]
                : [("none", nil)]

            for (resolutionLabel, longEdge) in longEdges {
                // Scale every frame once, outside the timed region.
                var scaledFrames: [Int: CVPixelBuffer] = [:]
                var scale = 1.0
                for (index, buffer) in frames {
                    if let longEdge {
                        let result = try SpikeBuffers.scaled(buffer, longEdge: longEdge, context: context)
                        scaledFrames[index] = result.buffer
                        scale = result.scale
                    } else {
                        scaledFrames[index] = buffer
                    }
                }

                for masking in maskings {
                    let registration = try await measureRegistration(
                        scenario: scenario, frames: scaledFrames, scale: scale, indices: indices,
                        resolution: resolutionLabel, masking: masking.label, masks: masking.masks
                    )
                    rows.append(registration)
                    printRow(registration)

                    for (accuracyLabel, level) in accuracies {
                        let row = try await measureFlow(
                            scenario: scenario, frames: scaledFrames, scale: scale, indices: indices,
                            resolution: resolutionLabel, accuracyLabel: accuracyLabel, level: level,
                            masking: masking.label, masks: masking.masks,
                            context: context, calibrations: &calibrations
                        )
                        rows.append(row)
                        printRow(row)
                    }
                }
            }
            _ = reference
        }

        let summary = makeSummary(rows: rows, indices: indices)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(summary).write(to: outDir.appendingPathComponent("summary.json"), options: .atomic)
        let markdown = renderMarkdown(summary)
        try markdown.write(to: outDir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print("\n" + markdown)
        print("wrote \(outDir.path)/summary.json and summary.md")
    }

    // MARK: - Measurement

    static func measureRegistration(
        scenario: Scenario, frames: [Int: CVPixelBuffer], scale: Double, indices: [Int],
        resolution: String, masking: String, masks: [Int: SubjectMask]?
    ) async throws -> Row {
        let estimator = VisionRegistrationEstimator()
        let reference = try prepared(frames[0]!, mask: masks?[0])
        let prepared = try indices.map { ($0, try Self.prepared(frames[$0]!, mask: masks?[$0])) }

        var stats = Stats()
        let sampler = FootprintSampler()
        sampler.start()

        // The first call pays one-off model/graph setup; measured separately so it does not
        // hide in an average, and because first-preview latency (PRD §1.3) pays it too.
        let warmStart = DispatchTime.now()
        _ = try? await estimator.estimate(frame: prepared[0].1, reference: reference)
        let warmupMs = SpikeFlowEstimator.milliseconds(since: warmStart)

        for (index, frame) in prepared {
            let start = DispatchTime.now()
            do {
                let motion = try await estimator.estimate(frame: frame, reference: reference)
                stats.requestMs.append(SpikeFlowEstimator.milliseconds(since: start))
                stats.rms.append(rms(of: motion.transform, scale: scale, scenario: scenario, index: index))
            } catch {
                stats.failures += 1
            }
        }
        return stats.row(
            scenario: scenario.name, estimator: "registration", accuracy: "-", resolution: resolution,
            masking: masking, frameCount: indices.count, warmupMs: warmupMs, peakMB: sampler.stop(),
            coverage: masks.map { $0.values.map(\.coverage).reduce(0, +) / Double($0.count) }
        )
    }

    static func measureFlow(
        scenario: Scenario, frames: [Int: CVPixelBuffer], scale: Double, indices: [Int],
        resolution: String, accuracyLabel: String, level: TrackOpticalFlowRequest.ComputationAccuracy,
        masking: String, masks: [Int: SubjectMask]?,
        context: CIContext, calibrations: inout [String: (scale: Double, milliseconds: Double)]
    ) async throws -> Row {
        let reference = frames[0]!
        let key = "\(resolution)/\(accuracyLabel)"
        let calibration: (scale: Double, milliseconds: Double)
        if let known = calibrations[key] {
            calibration = known
        } else {
            calibration = try await SpikeFlowEstimator.calibrate(reference: reference, accuracy: level, context: context)
            calibrations[key] = calibration
        }
        let estimator = SpikeFlowEstimator(accuracy: level, flowScale: calibration.scale)

        var stats = Stats()
        let sampler = FootprintSampler()
        sampler.start()

        let warmStart = DispatchTime.now()
        _ = try? await estimator.estimate(
            frame: frames[indices[0]]!, reference: reference,
            frameMask: masks?[indices[0]], referenceMask: masks?[0]
        )
        let warmupMs = SpikeFlowEstimator.milliseconds(since: warmStart)

        for index in indices {
            do {
                let result = try await estimator.estimate(
                    frame: frames[index]!, reference: reference,
                    frameMask: masks?[index], referenceMask: masks?[0]
                )
                stats.requestMs.append(result.requestMs)
                stats.extraMs.append(result.sampleMs + result.fitMs)
                stats.inlier.append(result.inlierRatio)
                stats.rms.append(rms(of: result.transform, scale: scale, scenario: scenario, index: index))
            } catch {
                stats.failures += 1
            }
        }
        return stats.row(
            scenario: scenario.name, estimator: "flow", accuracy: accuracyLabel, resolution: resolution,
            masking: masking, frameCount: indices.count, warmupMs: warmupMs, peakMB: sampler.stop(),
            coverage: masks.map { $0.values.map(\.coverage).reduce(0, +) / Double($0.count) },
            flowScale: calibration.scale, calibrationMs: calibration.milliseconds
        )
    }

    /// Registration's masking lever is to blank the subject out of the pixels themselves.
    static func prepared(_ buffer: CVPixelBuffer, mask: SubjectMask?) throws -> CVPixelBuffer {
        guard let mask else { return buffer }
        return try SpikeBuffers.blanked(buffer, mask: mask)
    }

    /// Error against the camera truth, in native pixels, relative to the reference frame's
    /// own truth (frame 0 need not be identity; see `MotionEstimationTests`).
    static func rms(of transform: simd_float3x3, scale: Double, scenario: Scenario, index: Int) -> Double {
        let truth = scenario.truth
        let expected = truth.frames[index].matrix * truth.frames[truth.referenceFrameIndex].matrix.inverse
        return SpikeAccuracy.rms(
            recovered: SpikeAccuracy.toNative(transform, scale: scale),
            truth: expected,
            frameSize: CGSize(width: truth.width, height: truth.height)
        )
    }

    struct Stats {
        var requestMs: [Double] = []
        var extraMs: [Double] = []
        var rms: [Double] = []
        var inlier: [Double] = []
        var failures = 0

        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }

        func row(
            scenario: String, estimator: String, accuracy: String, resolution: String, masking: String,
            frameCount: Int, warmupMs: Double, peakMB: Double, coverage: Double?,
            flowScale: Double? = nil, calibrationMs: Double? = nil
        ) -> Row {
            let request = mean(requestMs) ?? 0
            let extra = mean(extraMs) ?? 0
            return Row(
                scenario: scenario, estimator: estimator, accuracy: accuracy, resolution: resolution,
                masking: masking, frames: frameCount, failures: failures, warmupMs: warmupMs,
                requestMsPerFrame: request, sampleAndFitMsPerFrame: extra, totalMsPerFrame: request + extra,
                peakMemoryGrowthMB: peakMB, meanRMSpx: mean(rms), maxRMSpx: rms.max(),
                meanInlierRatio: mean(inlier), meanMaskCoverage: coverage,
                flowScale: flowScale, calibrationMs: calibrationMs
            )
        }
    }

    // MARK: - Scenarios

    static func loadTruth(_ name: String, in dir: URL) throws -> FixtureTruth {
        try FixtureTruth.load(from: dir.appendingPathComponent("\(name).truth.json"))
    }

    static func fileScenario(name: String, in dir: URL, withOracle: Bool = false) throws -> Scenario {
        let truth = try loadTruth(name, in: dir)
        let movieURL = dir.appendingPathComponent("\(name).mov")
        let oracle: ((Int) throws -> SubjectMask)? = withOracle
            ? { index in
                try oracleMask(rect: movingSubjectRect(size: 160), motion: FixtureGenerator.objectMotion, index: index)
            }
            : nil
        return Scenario(
            name: name,
            truth: truth,
            loadFrames: { indices in
                let asset = AVURLAsset(url: movieURL)
                let track = try await asset.loadTracks(withMediaType: .video)[0]
                let wanted = Set(indices)
                var found: [Int: CVPixelBuffer] = [:]
                var i = 0
                for buffer in try FrameSequence.make(asset: asset, track: track) {
                    if wanted.contains(i) { found[i] = buffer }
                    i += 1
                    if found.count == wanted.count { break }
                }
                return found
            },
            oracleMask: oracle
        )
    }

    static func movingSubjectRect(size: CGFloat) -> CGRect {
        CGRect(
            x: FixtureGenerator.canvasOrigin.x + 150, y: FixtureGenerator.canvasOrigin.y + 150,
            width: size, height: size
        )
    }

    /// The committed `moving-subject` object covers under 1% of the frame — too small to
    /// stress either estimator. This renders the same clip with a subject about a fifth of
    /// the frame (a person close to the camera), in memory, so the decision rule's
    /// "moving foreground" comparison is made on a case that matters. Nothing is committed.
    static func largeSubjectScenario(movingSubjectTruth: FixtureTruth, context: CIContext) throws -> Scenario {
        let shake = FixtureGenerator.shakeOffsets(seed: 0xC0FFEE_1234, count: FixtureGenerator.frameCount, magnitude: 8.0)
        let background = SyntheticCanvas.background(outputSize: FixtureGenerator.outputSize)
        let rect = movingSubjectRect(size: 640)
        let object = SyntheticCanvas.foregroundObject(
            size: FixtureGenerator.canvasSize, rect: rect, color: CIColor(red: 1.0, green: 0.55, blue: 0.0)
        )
        let motion: (Int) -> CGAffineTransform = { index in
            let f = FixtureGenerator.fraction(index)
            return CGAffineTransform(translationX: CGFloat(600.0 * f), y: CGFloat(200.0 * f))
        }
        let spec = FixtureGenerator.FixtureSpec(name: "moving-subject-large", layers: [
            .init(source: background, transform: { FixtureGenerator.translateShake($0, offsets: shake) }),
            .init(source: object, transform: motion),
        ])
        let width = Int(FixtureGenerator.outputSize.width)
        let height = Int(FixtureGenerator.outputSize.height)
        return Scenario(
            name: "moving-subject-large",
            truth: movingSubjectTruth,
            loadFrames: { indices in
                var found: [Int: CVPixelBuffer] = [:]
                for index in indices {
                    found[index] = try SpikeBuffers.render(
                        FixtureGenerator.render(spec: spec, index: index), width: width, height: height, context: context
                    )
                }
                return found
            },
            oracleMask: { index in try oracleMask(rect: rect, motion: motion, index: index) }
        )
    }

    /// Where the subject really is: render only the subject, in white on black, through the
    /// same transform the generator used, then read it onto the mask grid.
    static func oracleMask(rect: CGRect, motion: @escaping (Int) -> CGAffineTransform, index: Int) throws -> SubjectMask {
        let white = SyntheticCanvas.foregroundObject(size: FixtureGenerator.canvasSize, rect: rect, color: CIColor(red: 1, green: 1, blue: 1))
        let spec = FixtureGenerator.FixtureSpec(name: "oracle", layers: [.init(source: white, transform: motion)])
        let frame = FixtureGenerator.render(spec: spec, index: index)
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: FixtureGenerator.outputSize))
        let scale = CGFloat(SubjectMask.gridWidth) / FixtureGenerator.outputSize.width
        let small = frame.composited(over: black).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let buffer = try SpikeBuffers.render(small, width: SubjectMask.gridWidth, height: SubjectMask.gridHeight, context: CIContext())
        return try SubjectMask.fromBrightness(buffer, dilationRadius: maskDilationCells)
    }

    /// Vision's foreground-instance mask on a 720-long-edge copy of the frame. Returns an
    /// empty mask when Vision finds no foreground, which is a real outcome to report.
    static func visionForegroundMask(_ frame: CVPixelBuffer, context: CIContext) async throws -> SubjectMask {
        let small = try SpikeBuffers.scaled(frame, longEdge: 720, context: context).buffer
        let handler = ImageRequestHandler(small)
        guard let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest()) else {
            return SubjectMask(cells: [UInt8](repeating: 0, count: SubjectMask.gridWidth * SubjectMask.gridHeight))
        }
        let buffer = try observation.generateScaledMask(for: observation.allInstances, scaledToImageFrom: handler)
        return try SubjectMask.fromSingleChannel(buffer, dilationRadius: maskDilationCells)
    }

    // MARK: - Reporting

    static func printRow(_ r: Row) {
        let rms = r.meanRMSpx.map { String(format: "%.3f", $0) } ?? "n/a"
        let maxRms = r.maxRMSpx.map { String(format: "%.3f", $0) } ?? "n/a"
        print(String(
            format: "   %@ %@ %@ mask=%@ -> %.1f ms/frame (warmup %.0f), rms %@ (max %@), fail %d, +%.0f MB",
            r.estimator, r.accuracy, r.resolution, r.masking, r.totalMsPerFrame, r.warmupMs, rms, maxRms, r.failures, r.peakMemoryGrowthMB
        ))
    }

    static func makeSummary(rows: [Row], indices: [Int]) -> Summary {
        // Cost is a property of the estimator, not the clip, so extrapolate from `combined`
        // (full camera motion, no subject) at 720 px.
        let scenario = "combined"
        var seconds: [String: Double] = [:]
        for row in rows where row.scenario == scenario && row.resolution == "720" && row.masking == "none" {
            let key = row.estimator == "flow" ? "flow-\(row.accuracy)" : "registration"
            seconds[key] = row.totalMsPerFrame * Double(FixtureGenerator.frameCount) / 1000
        }
        var machine = [UInt8](repeating: 0, count: 256)
        var size = machine.count
        sysctlbyname("machdep.cpu.brand_string", &machine, &size, nil, 0)
        return Summary(
            machine: String(decoding: machine.prefix { $0 != 0 }, as: UTF8.self),
            os: ProcessInfo.processInfo.operatingSystemVersionString,
            frameIndices: indices,
            rows: rows,
            extrapolationScenario: scenario,
            threeSecondClipSecondsAt720: seconds
        )
    }

    static func renderMarkdown(_ summary: Summary) -> String {
        var out = "# Estimator benchmark\n\nMachine: \(summary.machine), macOS \(summary.os). "
        out += "Frames per config: \(summary.frameIndices.count) (indices \(summary.frameIndices.map(String.init).joined(separator: ","))).\n\n"
        out += "| scenario | estimator | accuracy | res | mask | ms/frame | warmup ms | mean RMS px | max RMS px | inliers | fails | +MB |\n"
        out += "| --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n"
        for r in summary.rows {
            let mean = r.meanRMSpx.map { String(format: "%.3f", $0) } ?? "n/a"
            let max = r.maxRMSpx.map { String(format: "%.3f", $0) } ?? "n/a"
            let inl = r.meanInlierRatio.map { String(format: "%.2f", $0) } ?? "-"
            out += String(
                format: "| %@ | %@ | %@ | %@ | %@ | %.1f | %.0f | %@ | %@ | %@ | %d | %.0f |\n",
                r.scenario, r.estimator, r.accuracy, r.resolution, r.masking, r.totalMsPerFrame, r.warmupMs, mean, max, inl, r.failures, r.peakMemoryGrowthMB
            )
        }
        out += "\n## 3 s clip (90 frames) at 720 px, from `\(summary.extrapolationScenario)`\n\n| estimator | seconds |\n| --- | ---: |\n"
        for (key, value) in summary.threeSecondClipSecondsAt720.sorted(by: { $0.key < $1.key }) {
            out += String(format: "| %@ | %.2f |\n", key, value)
        }
        return out
    }
}
