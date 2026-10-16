import AVFoundation
import CoreImage
import Foundation
import StillMotionsPipeline

/// The default `stillmotions-harness` run (PRD R-20, R-22, R-23): process every clip in a folder
/// through the shipping pipeline, write the outputs and metrics, and compare with the baseline.
///
///     stillmotions-harness --fixtures <dir> --out <dir> [--baseline harness/baseline.json]
///                          [--estimator registration|registration-direct|flow] [--solver warp|l1] [--update-baseline]
///
/// `scripts/verify.sh` calls exactly this interface.
enum HarnessRunner {
    struct Options {
        var fixtures: URL
        var out: URL
        var baseline: URL?
        var estimator = "registration"
        var solver = "warp"
        var updateBaseline = false
    }

    static let usage = """
        usage: stillmotions-harness --fixtures <dir> --out <dir> [--baseline <file>]
                                    [--estimator registration|registration-direct|flow] [--solver warp|l1] [--update-baseline]
        """

    static func parse(_ arguments: [String]) throws -> Options {
        var fixtures: URL?, out: URL?, baseline: URL?
        var estimator = "registration", solver = "warp", update = false
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < arguments.count else { throw SpikeError("\(flag) needs a value\n\(usage)") }
            return arguments[i]
        }
        while i < arguments.count {
            switch arguments[i] {
            case "--fixtures": fixtures = URL(fileURLWithPath: try value("--fixtures"), isDirectory: true)
            case "--out": out = URL(fileURLWithPath: try value("--out"), isDirectory: true)
            case "--baseline": baseline = URL(fileURLWithPath: try value("--baseline"))
            case "--estimator": estimator = try value("--estimator")
            case "--solver": solver = try value("--solver")
            case "--update-baseline": update = true
            default: throw SpikeError("unknown argument '\(arguments[i])'\n\(usage)")
            }
            i += 1
        }
        guard let fixtures else { throw SpikeError("--fixtures is required\n\(usage)") }
        guard let out else { throw SpikeError("--out is required\n\(usage)") }
        guard ["registration", "registration-direct", "flow"].contains(estimator) else {
            throw SpikeError("--estimator must be 'registration', 'registration-direct' or 'flow', not '\(estimator)'")
        }
        guard ["warp", "l1"].contains(solver) else { throw SpikeError("--solver must be 'warp' or 'l1', not '\(solver)'") }
        return Options(fixtures: fixtures, out: out, baseline: baseline, estimator: estimator, solver: solver, updateBaseline: update)
    }

    // MARK: - Reports

    struct OutputReport: Codable {
        let file: String
        let format: String
        let mode: String
        let preset: String
        let bytes: Int?
        let frames: Int?
        let width: Int?
        let height: Int?
        /// Set when the output could not be produced here (for example no HEVC encoder).
        let skipped: String?
    }

    struct LoopReport: Codable {
        let startIndex: Int
        let returnIndex: Int
        let length: Int
        let seamRatioBeforeCrossfade: Double
        let seamRatio: Double
    }

    struct ClipReport: Codable {
        let name: String
        let width: Int
        let height: Int
        let frameCount: Int
        let frameRate: Double
        let referenceIndex: Int
        let estimator: String
        let solver: String
        let estimationFailures: Int
        let metrics: ClipMetrics
        let failures: [String]
        let crop: [Double]
        let loop: LoopReport?
        let residualPairs: Int
        let residualSkippedPairs: Int
        /// Mean RMS error of the recovered transforms against the fixture's known motion, in
        /// native pixels. Only for synthetic fixtures.
        let truthRMSpx: Double?
        let outputs: [OutputReport]
        let timingsMs: [String: Double]
        /// Why the clip could not be processed at all (for example no common area to crop to).
        /// Such a clip counts as a stabilization failure; it does not stop the run.
        let error: String?
    }

    struct Summary: Codable {
        let estimator: String
        let solver: String
        let clipCount: Int
        let passedCount: Int
        let medianCropRetention: Double
        /// `nil` when residual motion was not measured (no optical flow on this machine).
        let medianResidualMotionPx: Double?
        let medianLoopSeamRatio: Double
        let regressionProblems: [String]
        let clips: [ClipReport]
    }

    // MARK: - Run

    /// Returns the process exit code.
    static func run(arguments: [String]) async throws -> Int32 {
        let options = try parse(arguments)
        guard options.solver == "warp" else {
            throw SpikeError("--solver l1: L1OptimalSolver is not built. It is conditional on the crop-retention gate (decision 0002, issue #21).")
        }
        try FileManager.default.createDirectory(at: options.out, withIntermediateDirectories: true)

        let clips = try ClipLocator.find(in: options.fixtures)
        guard !clips.isEmpty else { throw SpikeError("no .mov clips found in \(options.fixtures.path)") }

        let flowAvailable = await FlowAvailability.probe()
        if options.estimator == "flow", !flowAvailable {
            throw SpikeError("--estimator flow: Vision optical flow does not run on this machine (it fails on GitHub-hosted runners)")
        }
        if options.updateBaseline, !flowAvailable {
            throw SpikeError("--update-baseline needs residual motion, and Vision optical flow does not run on this machine. Writing a baseline without it would silently drop the residual-motion check; run this on a Mac.")
        }
        if !flowAvailable {
            print("note: Vision optical flow is unavailable on this machine, so residual motion is NOT measured (crop retention and loop seam still are)")
        }
        let estimator: any MotionEstimator = options.estimator == "flow" ? FlowMotionEstimator() : VisionRegistrationEstimator()
        var reports: [ClipReport] = []
        for clip in clips {
            print("== \(clip.name)")
            let report: ClipReport
            do {
                report = try await process(clip, options: options, estimator: estimator, flowAvailable: flowAvailable)
            } catch {
                // A clip that cannot be processed is a stabilization failure to report, not a
                // reason to abandon the other clips (real footage will contain some).
                report = failedReport(clip, options: options, error: error)
            }
            reports.append(report)
            let m = report.metrics
            print(String(
                format: "   crop %.1f%%  residual %@  seam %@  %@  (%.1f s)",
                m.cropRetention * 100, m.residualMotion.map { String(format: "%.3f px", $0) } ?? "not measured",
                m.loopSeamRatio.map { String(format: "%.2fx", $0) } ?? "n/a",
                m.passed ? "PASS" : "FAIL: " + report.failures.joined(separator: ", ") + (report.error.map { " (\($0))" } ?? ""),
                (report.timingsMs["total"] ?? 0) / 1000
            ))
        }

        let metrics = Dictionary(uniqueKeysWithValues: reports.map { ($0.name, $0.metrics) })
        var problems: [String] = []
        if options.updateBaseline {
            let url = options.baseline ?? URL(fileURLWithPath: "harness/baseline.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Baseline(clips: metrics, estimator: options.estimator, solver: options.solver, residualMeter: ResidualMotionMeter().identifier).write(to: url)
            print("wrote baseline \(url.path)")
        } else if let baselineURL = options.baseline {
            guard FileManager.default.fileExists(atPath: baselineURL.path) else {
                throw SpikeError("baseline \(baselineURL.path) does not exist (create it with --update-baseline)")
            }
            problems = RegressionCheck.compare(
                baseline: try Baseline.load(from: baselineURL), current: metrics,
                residualMeter: flowAvailable ? ResidualMotionMeter().identifier : nil
            )
        }

        let summary = Summary(
            estimator: options.estimator, solver: options.solver,
            clipCount: reports.count, passedCount: reports.filter { $0.metrics.passed }.count,
            medianCropRetention: RegressionCheck.median(reports.map(\.metrics.cropRetention)),
            medianResidualMotionPx: reports.contains { $0.metrics.residualMotion != nil } ? RegressionCheck.median(reports.compactMap(\.metrics.residualMotion)) : nil,
            medianLoopSeamRatio: RegressionCheck.median(reports.compactMap(\.metrics.loopSeamRatio)),
            regressionProblems: problems, clips: reports
        )
        try write(summary, to: options.out.appendingPathComponent("summary.json"))
        print(String(
            format: "\n%d clips, %d pass every measured threshold. median crop %.1f%%, residual %@, seam %.2fx",
            summary.clipCount, summary.passedCount, summary.medianCropRetention * 100,
            summary.medianResidualMotionPx.map { String(format: "%.3f px", $0) } ?? "not measured", summary.medianLoopSeamRatio
        ))
        if problems.isEmpty {
            if options.baseline != nil, !options.updateBaseline { print("REGRESSION CHECK PASSED against \(options.baseline!.path)") }
            return 0
        }
        print("\nREGRESSION CHECK FAILED:")
        for problem in problems { print("  - \(problem)") }
        return 1
    }

    /// What a clip that could not be processed looks like in the results: zero crop retention,
    /// so it fails the crop threshold and is counted, with the reason attached.
    static func failedReport(_ clip: ClipInput, options: Options, error: Error) -> ClipReport {
        let metrics = ClipMetrics(cropRetention: 0)
        return ClipReport(
            name: clip.name, width: 0, height: 0, frameCount: 0, frameRate: 0, referenceIndex: 0,
            estimator: options.estimator, solver: options.solver, estimationFailures: 0,
            metrics: metrics, failures: metrics.failures.map(\.rawValue), crop: [], loop: nil,
            residualPairs: 0, residualSkippedPairs: 0, truthRMSpx: nil, outputs: [], timingsMs: [:],
            error: "\(error)"
        )
    }

    // MARK: - One clip

    static func process(_ clip: ClipInput, options: Options, estimator: any MotionEstimator, flowAvailable: Bool) async throws -> ClipReport {
        let outDir = options.out.appendingPathComponent(clip.name, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let renderer = StabilizedRenderer()
        var timings: [String: Double] = [:]
        let start = ContinuousClock.now
        func timed<T>(_ stage: String, _ work: () async throws -> T) async rethrows -> T {
            let t0 = ContinuousClock.now
            defer { timings[stage] = milliseconds(ContinuousClock.now - t0) }
            return try await work()
        }

        let referenceIndex = try await clip.referenceIndex()
        let analysis = try await timed("estimate") {
            try await ClipAnalyzer.estimateMotion(
                movieURL: clip.movieURL, referenceIndex: referenceIndex, estimator: estimator,
                strategy: options.estimator == "registration" ? .chained : .reference, renderer: renderer
            )
        }
        let path = try await timed("solve") {
            try WarpToReferenceSolver().solve(motion: analysis.motion, frameSize: analysis.size)
        }

        // Loop selection runs on signatures of the stabilized, cropped frames.
        let loop: LoopSelection? = try await timed("loopSelection") {
            let signatures = try await ClipAnalyzer.signatures(movieURL: clip.movieURL, path: path, renderer: renderer)
            if case .selected(let selection) = try LoopSelector.select(signatures: signatures, frameRate: analysis.frameRate, mode: .loop) {
                return selection
            }
            return nil
        }

        // Residual motion on the stabilized frames at preview size, in playback order.
        let residual: ResidualMotionMeter.Result? = try await timed("residualMotion") {
            guard flowAvailable else { return nil }
            let asset = AVURLAsset(url: clip.movieURL)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ClipImportError.noVideoTrack(clip.movieURL) }
            let next = try renderer.makeProducer(
                frames: try FrameSequence.make(asset: asset, track: track), corrections: path.corrections,
                crop: path.crop, outputSize: OutputSize.size(forCrop: path.crop, longEdge: 720)
            )
            return try await ResidualMotionMeter().measure(next: next)
        }

        let metrics = ClipMetrics(
            cropRetention: path.cropRetention, residualMotion: residual?.meanPixels, loopSeamRatio: loop?.seamRatio
        )

        let outputs = await timed("export") { await export(clip: clip, path: path, loop: loop, to: outDir, renderer: renderer) }
        try await timed("contactSheet") {
            try await ContactSheet.write(
                movieURL: clip.movieURL, path: path, frameCount: analysis.motion.count,
                to: outDir.appendingPathComponent("contact-sheet.png"), renderer: renderer
            )
        }

        var truthRMS: Double?
        if let truth = clip.truth {
            let inverse = truth.frames[truth.referenceFrameIndex].matrix.inverse
            let errors = analysis.motion.map { frame in
                SpikeAccuracy.rms(
                    recovered: frame.transform, truth: truth.frames[frame.index].matrix * inverse,
                    frameSize: CGSize(width: truth.width, height: truth.height)
                )
            }
            truthRMS = errors.reduce(0, +) / Double(errors.count)
        }

        timings["total"] = milliseconds(ContinuousClock.now - start)
        let report = ClipReport(
            name: clip.name, width: Int(analysis.size.width), height: Int(analysis.size.height),
            frameCount: analysis.motion.count, frameRate: analysis.frameRate, referenceIndex: referenceIndex,
            estimator: options.estimator, solver: options.solver, estimationFailures: analysis.estimationFailures,
            metrics: metrics, failures: metrics.failures.map(\.rawValue),
            crop: [Double(path.crop.minX), Double(path.crop.minY), Double(path.crop.width), Double(path.crop.height)].map { ($0 * 100).rounded() / 100 },
            loop: loop.map {
                LoopReport(
                    startIndex: $0.startIndex, returnIndex: $0.returnIndex, length: $0.length,
                    seamRatioBeforeCrossfade: $0.seamRatioBeforeCrossfade, seamRatio: $0.seamRatio
                )
            },
            residualPairs: residual?.pairs ?? 0, residualSkippedPairs: residual?.skippedPairs ?? 0,
            truthRMSpx: truthRMS, outputs: outputs, timingsMs: timings.mapValues { ($0 * 10).rounded() / 10 },
            error: nil
        )
        try write(report, to: outDir.appendingPathComponent("metrics.json"))
        return report
    }

    /// A loop GIF and a play-once MP4 at each size preset. A failure to produce one is recorded
    /// against that output instead of abandoning the clip, so one missing encoder (a Mac with no
    /// HEVC, say) cannot hide every other result.
    static func export(clip: ClipInput, path: CameraPath, loop: LoopSelection?, to dir: URL, renderer: StabilizedRenderer) async -> [OutputReport] {
        var reports: [OutputReport] = []
        for preset in SizePreset.allCases {
            let tag = preset.longEdge.map(String.init) ?? "native"
            let gifName = "loop-\(tag).gif"
            do {
                let result = try await ClipExporter.exportGIF(
                    movieURL: clip.movieURL, path: path, preset: preset, frameRate: .fps20, mode: .loop,
                    loop: loop, to: dir.appendingPathComponent(gifName), renderer: renderer
                )
                reports.append(OutputReport(
                    file: gifName, format: "gif", mode: "loop", preset: preset.rawValue, bytes: fileSize(dir.appendingPathComponent(gifName)),
                    frames: result.frameCount, width: result.width, height: result.height, skipped: nil
                ))
            } catch {
                reports.append(OutputReport(file: gifName, format: "gif", mode: "loop", preset: preset.rawValue, bytes: nil, frames: nil, width: nil, height: nil, skipped: "\(error)"))
            }

            let mp4Name = "once-\(tag).mp4"
            do {
                let result = try await ClipExporter.exportVideo(
                    movieURL: clip.movieURL, path: path, preset: preset, mode: .once,
                    to: dir.appendingPathComponent(mp4Name), renderer: renderer
                )
                reports.append(OutputReport(
                    file: mp4Name, format: "mp4", mode: "once", preset: preset.rawValue, bytes: fileSize(dir.appendingPathComponent(mp4Name)),
                    frames: result.frameCount, width: result.width, height: result.height, skipped: nil
                ))
            } catch {
                reports.append(OutputReport(file: mp4Name, format: "mp4", mode: "once", preset: preset.rawValue, bytes: nil, frames: nil, width: nil, height: nil, skipped: "\(error)"))
            }
        }
        return reports
    }

    // MARK: - Helpers

    static func fileSize(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}
