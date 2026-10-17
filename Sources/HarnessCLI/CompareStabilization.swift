import Foundation
import StillMotionsPipeline

/// `stillmotions-harness compare-stabilization --fixtures <dir> --out <dir>`: every stabilization mode
/// (and several strengths of Smooth) side by side on every clip (issue #84).
///
/// Motion is estimated ONCE per clip and every variant is solved from it, which is how the app will
/// switch modes; it also makes a sweep take one estimation per clip rather than one per variant.
enum CompareStabilization {
    struct Variant {
        let name: String
        let mode: StabilizationMode
        let solver: (any CameraPathSolver)?
    }

    static var variants: [Variant] { [
        Variant(name: "off", mode: .off, solver: nil),
        Variant(name: "locked", mode: .locked, solver: nil),
        Variant(name: "smooth-8", mode: .smooth, solver: SmoothedPathSolver(sigmaFrames: 8)),
        Variant(name: "smooth-16", mode: .smooth, solver: SmoothedPathSolver(sigmaFrames: 16)),
        // Half and double the default cap on how far any frame may be moved.
        Variant(name: "smooth-8-tight", mode: .smooth, solver: SmoothedPathSolver(sigmaFrames: 8, maxShiftFraction: 0.025, maxRotation: 0.015, maxLogScale: 0.025)),
        Variant(name: "smooth-8-loose", mode: .smooth, solver: SmoothedPathSolver(sigmaFrames: 8, maxShiftFraction: 0.10, maxRotation: 0.06, maxLogScale: 0.10)),
    ] }

    struct Row: Codable {
        let clip: String
        let variant: String
        let cropRetention: Double
        let residualMotion: Double?
        let loopSeamRatio: Double?
        let stabilized: Bool
    }

    static func run(arguments: [String]) async throws {
        var fixtures: URL?, out: URL?
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--fixtures": i += 1; fixtures = URL(fileURLWithPath: arguments[i], isDirectory: true)
            case "--out": i += 1; out = URL(fileURLWithPath: arguments[i], isDirectory: true)
            default: throw SpikeError("unknown argument '\(arguments[i])'\nusage: stillmotions-harness compare-stabilization --fixtures <dir> --out <dir>")
            }
            i += 1
        }
        guard let fixtures, let out else { throw SpikeError("--fixtures and --out are required") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let clips = try ClipLocator.find(in: fixtures)
        guard !clips.isEmpty else { throw SpikeError("no .mov clips found in \(fixtures.path)") }
        let flowAvailable = await FlowAvailability.probe()
        if !flowAvailable { print("note: optical flow is unavailable here, so residual motion is not measured") }

        var rows: [Row] = []
        let renderer = StabilizedRenderer()
        for clip in clips {
            do {
                let reference = try await clip.referenceIndex()
                let motion = try await ClipAnalyzer.estimateMotion(
                    movieURL: clip.movieURL, referenceIndex: reference, estimator: VisionRegistrationEstimator(),
                    strategy: .chained, renderer: renderer
                )
                var line = "\(clip.name):"
                for variant in variants {
                    let analysis = try await ClipAnalyzer.analyze(
                        movieURL: clip.movieURL, motion: motion, mode: variant.mode, solver: variant.solver,
                        residualMotion: flowAvailable
                            ? { path in try await ResidualMotionMeter.measure(movieURL: clip.movieURL, path: path, renderer: renderer).meanPixels }
                            : nil,
                        renderer: renderer
                    )
                    let m = analysis.metrics
                    rows.append(Row(
                        clip: clip.name, variant: variant.name, cropRetention: m.cropRetention,
                        residualMotion: analysis.measuredResidualMotion, loopSeamRatio: m.loopSeamRatio, stabilized: analysis.stabilized
                    ))
                    line += String(format: " %@ %.0f%%/%@", variant.name, m.cropRetention * 100, m.residualMotion.map { String(format: "%.2f", $0) } ?? "-")
                }
                print(line)
            } catch {
                print("\(clip.name): FAILED (\(error))")
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: out.appendingPathComponent("rows.json"))
        let table = markdown(rows)
        try table.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print("\n" + table)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    static func markdown(_ rows: [Row]) -> String {
        var out = "| variant | clips | median crop | crop < 60% | median residual (px) | residual >= 1 px | median seam |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: |\n"
        for variant in variants {
            let mine = rows.filter { $0.variant == variant.name }
            guard !mine.isEmpty else { continue }
            let residuals = mine.compactMap(\.residualMotion), seams = mine.compactMap(\.loopSeamRatio)
            out += String(
                format: "| %@ | %d | %.1f%% | %d | %@ | %d | %@ |\n",
                variant.name, mine.count, median(mine.map(\.cropRetention)) * 100,
                mine.filter { $0.cropRetention < QualityThresholds.minimumCropRetention }.count,
                residuals.isEmpty ? "-" : String(format: "%.2f", median(residuals)),
                residuals.filter { $0 >= QualityThresholds.maximumResidualMotion }.count,
                seams.isEmpty ? "-" : String(format: "%.2f", median(seams))
            )
        }
        return out
    }
}
