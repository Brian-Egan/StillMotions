import AVFoundation
import CoreVideo
import Foundation
import StillMotionsPipeline

/// `stillmotions-harness reference-compare --fixtures <dir> --out <dir>` (issue #98).
///
/// For each clip that has another app's stabilized GIF beside it (`*.motionstills-output.gif` or
/// `*.reference.gif`), measures how much the PICTURE moves in the original, in that reference, and in
/// every stabilization variant we produce, all by the same method and at the same size
/// (`OutputMotion`). That is the comparison a viewer makes: not what our solver believes it did, but
/// what the frames show.
enum ReferenceCompare {
    struct Row: Codable {
        let clip: String
        let name: String
        /// Share of the frame kept, 0...1. Nil for the original (all of it) and for a reference GIF
        /// (not measured here: it needs template matching against the source).
        let cropKept: Double?
        let motion: OutputMotion.Result
    }

    static func run(arguments: [String]) async throws {
        var fixtures: URL?, out: URL?
        var diagnose = false, masking = false, peopleOnly = false
        var maskEdge = 720
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--fixtures": i += 1; fixtures = URL(fileURLWithPath: arguments[i], isDirectory: true)
            case "--out": i += 1; out = URL(fileURLWithPath: arguments[i], isDirectory: true)
            case "--diagnose": diagnose = true
            case "--masking": masking = true
            case "--people-only": peopleOnly = true
            case "--mask-edge": i += 1; maskEdge = Int(arguments[i]) ?? 720
            default: throw SpikeError("unknown argument '\(arguments[i])'\nusage: stillmotions-harness reference-compare --fixtures <dir> --out <dir>")
            }
            i += 1
        }
        guard let fixtures, let out else { throw SpikeError("--fixtures and --out are required") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        var rows: [Row] = []
        for clip in try ClipLocator.find(in: fixtures) {
            let folder = clip.movieURL.deletingLastPathComponent()
            let references = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                .filter { $0.hasSuffix(".motionstills-output.gif") || $0.hasSuffix(".reference.gif") }.sorted()
            guard let referenceName = references.first else { continue }
            print("\(clip.name): reference \(referenceName)")
            rows += try await compare(clip: clip, referenceGIF: folder.appendingPathComponent(referenceName), diagnose: diagnose, masker: masking ? SubjectMasker(configuration: .init(analysisLongEdge: maskEdge, usesForegroundInstances: !peopleOnly)) : nil)
        }
        guard !rows.isEmpty else { throw SpikeError("no clip with a *.motionstills-output.gif or *.reference.gif beside it in \(fixtures.path)") }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: out.appendingPathComponent("rows.json"))
        let table = markdown(rows)
        try table.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        print("\n" + table)
    }

    static func compare(clip: ClipInput, referenceGIF: URL, diagnose: Bool, masker: SubjectMasker?) async throws -> [Row] {
        let renderer = StabilizedRenderer()
        var rows: [Row] = []

        let gif = OutputMotion.grayFrames(ofGIF: referenceGIF)
        let reference = OutputMotion.measure(frames: gif.frames, times: gif.times)
        rows.append(Row(clip: clip.name, name: "reference GIF", cropKept: nil, motion: reference))

        let referenceIndex = try await clip.referenceIndex()
        let estimateStart = ContinuousClock.now
        let motion = try await ClipAnalyzer.estimateMotion(
            movieURL: clip.movieURL, referenceIndex: referenceIndex, estimator: VisionRegistrationEstimator(),
            strategy: .chained, masker: masker, renderer: renderer
        )
        let estimateSeconds = Double((ContinuousClock.now - estimateStart).components.seconds) + Double((ContinuousClock.now - estimateStart).components.attoseconds) / 1e18
        print(String(format: "motion estimate took %.2f s%@ (Mac; says nothing about the phone)", estimateSeconds, masker == nil ? "" : " with subject masking"))
        if diagnose { printPoses(motion) }
        let identity = Array(repeating: matrix_identity_float3x3, count: motion.motion.count)
        let whole = CGRect(origin: .zero, size: motion.size)
        rows.append(Row(clip: clip.name, name: "original", cropKept: 1,
                        motion: try await measure(clip: clip, corrections: identity, crop: whole, times: motion.frameTimes, renderer: renderer)))

        for variant in CompareStabilization.variants {
            let analysis = try await ClipAnalyzer.analyze(
                movieURL: clip.movieURL, motion: motion, mode: variant.mode, solver: variant.solver, renderer: renderer
            )
            let result = try await measure(clip: clip, corrections: analysis.path.corrections, crop: analysis.path.crop, times: motion.frameTimes, renderer: renderer)
            rows.append(Row(clip: clip.name, name: variant.name, cropKept: analysis.path.cropRetention, motion: result))
        }
        return rows
    }

    /// The estimated pose of each frame as shift, scale and rotation, for finding where an estimate goes wrong.
    /// Shift is in source pixels; `step` is how far the shift moved since the frame before.
    static func printPoses(_ motion: ClipAnalyzer.MotionResult) {
        print("estimation failures: \(motion.estimationFailures) of \(motion.motion.count) frames, size \(Int(motion.size.width))x\(Int(motion.size.height))")
        print("frame     tx      ty    scale  rot(deg)  persp   step")
        var previous: SIMD2<Float>?
        for frame in motion.motion {
            let t = frame.transform
            let w = t[2][2]
            let a = t[0][0] / w, b = t[0][1] / w, c = t[1][0] / w, d = t[1][1] / w
            let tx = t[2][0] / w, ty = t[2][1] / w
            let scale = (abs(a * d - b * c)).squareRoot()
            let rotation = atan2(b, a) * 180 / .pi
            let persp = max(abs(t[0][2]), abs(t[1][2])) / w
            let step = previous.map { simd_distance($0, SIMD2(tx, ty)) } ?? 0
            previous = SIMD2(tx, ty)
            print(String(format: "%3d  %7.1f %7.1f  %6.3f  %7.2f  %.1e  %6.1f", frame.index, tx, ty, scale, rotation, persp, step))
        }
    }

    /// Renders every frame with `corrections` and `crop` at the analysis size and measures the picture.
    static func measure(clip: ClipInput, corrections: [simd_float3x3], crop: CGRect, times: [Double], renderer: StabilizedRenderer) async throws -> OutputMotion.Result {
        let asset = AVURLAsset(url: clip.movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpikeError("no video track") }
        let size = CGSize(width: OutputMotion.width, height: OutputMotion.height)
        var frames: [[Float]] = []
        for (index, frame) in try FrameSequence.make(asset: asset, track: track).enumerated() {
            guard index < corrections.count else { break }
            let rendered = try renderer.render(frame: frame, correction: corrections[index], crop: crop, outputSize: size)
            frames.append(OutputMotion.gray(of: rendered))
        }
        return OutputMotion.measure(frames: frames, times: times)
    }

    static func markdown(_ rows: [Row]) -> String {
        var out = ""
        for clip in Array(Set(rows.map(\.clip))).sorted() {
            out += "### \(clip)\n\n"
            out += "| picture | frames | frame kept | jitter px | x range | y range | net pan | biggest step (at frame) | steps > 3 px |\n| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |\n"
            for row in rows where row.clip == clip {
                let m = row.motion
                let jumps = m.bigSteps.map { "\(Int($0[0])): \(String(format: "%.1f", $0[1]))" }.joined(separator: ", ")
                out += String(
                    format: "| %@ | %d | %@ | %.2f | %.0f | %.0f | %.0f | %.1f (%d) | %@ |\n",
                    row.name, m.frames, row.cropKept.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a",
                    m.jitter, m.xRange, m.yRange, m.netPan, m.stepMax, m.stepMaxFrame, jumps.isEmpty ? "none" : jumps
                )
            }
            out += "\nJitter is the RMS of the picture's path from its own 0.3 s moving average, in pixels at 180x240, measured by phase correlation on the rendered frames. Net pan is how far the path ends from where it started.\n\n"
        }
        return out
    }
}
