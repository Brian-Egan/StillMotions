import AVFoundation
import CoreImage
import Foundation
import StillMotionsPipeline

/// `stillmotions-harness estimation-failures --fixtures <dir>` (issue #92).
///
/// Lists, per clip, how many frames the motion estimator rejected, which rule rejected them (the estimator
/// finding nothing, or the plausibility check on scale, rotation or shift), and a few cheap properties of
/// the clip (brightness, detail, frame rate, size), to see what the clips with many rejections share.
/// A rejected step assumes no motion, so those frames are not stabilized.
enum EstimationFailures {
    struct Row: Codable {
        let clip: String
        let frames: Int
        let failures: Int
        let byRule: [String: Int]
        let reasons: [String]
        let meanLuma: Double          // 0...255, of the reference frame
        let detail: Double            // mean absolute gradient of the reference frame at 256x256, 0...255
        let frameRate: Double
        let width: Int, height: Int
    }

    static func run(arguments: [String]) async throws {
        var fixtures: URL?, out: URL?
        var oldDarkening = false
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--fixtures": i += 1; fixtures = URL(fileURLWithPath: arguments[i], isDirectory: true)
            case "--out": i += 1; out = URL(fileURLWithPath: arguments[i], isDirectory: true)
            case "--old-darkening": oldDarkening = true
            default: throw SpikeError("unknown argument '\(arguments[i])'\nusage: stillmotions-harness estimation-failures --fixtures <dir> [--out <dir>] [--old-darkening]")
            }
            i += 1
        }
        guard let fixtures else { throw SpikeError("--fixtures is required") }
        let clips = try ClipLocator.find(in: fixtures)
        var rows: [Row] = []
        let renderer = StabilizedRenderer()
        for (index, clip) in clips.enumerated() {
            do {
                let reference = try await clip.referenceIndex()
                let motion = try await ClipAnalyzer.estimateMotion(
                    movieURL: clip.movieURL, referenceIndex: reference,
                    estimator: oldDarkening ? DarkenedEstimator(inner: VisionRegistrationEstimator()) : VisionRegistrationEstimator(),
                    strategy: .chained, renderer: renderer
                )
                let (luma, detail) = try await referenceFrameProperties(clip: clip, index: reference, size: motion.size, renderer: renderer)
                rows.append(Row(
                    clip: clip.name, frames: motion.motion.count, failures: motion.estimationFailures,
                    byRule: classify(motion.failureReasons), reasons: motion.failureReasons, meanLuma: luma, detail: detail,
                    frameRate: motion.frameRate, width: Int(motion.size.width), height: Int(motion.size.height)
                ))
                print("[\(index + 1)/\(clips.count)] \(clip.name): \(motion.estimationFailures) rejected of \(motion.motion.count)")
            } catch {
                print("[\(index + 1)/\(clips.count)] \(clip.name): FAILED (\(error))")
            }
        }
        if let out {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: out.appendingPathComponent("rows.json"))
        }
        print("\n" + summary(rows))
    }

    /// Which rule rejected a frame, from the text of the error.
    static func classify(_ reasons: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for reason in reasons {
            let rule: String
            if reason.contains("scale") { rule = "scale" }
            else if reason.contains("rotation") { rule = "rotation" }
            else if reason.contains("translation") { rule = "translation" }
            else { rule = "estimator found nothing" }
            counts[rule, default: 0] += 1
        }
        return counts
    }

    static func referenceFrameProperties(clip: ClipInput, index: Int, size: CGSize, renderer: StabilizedRenderer) async throws -> (Double, Double) {
        let asset = AVURLAsset(url: clip.movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return (0, 0) }
        let target = CGSize(width: OutputMotion.width, height: OutputMotion.height)
        for (i, frame) in try FrameSequence.make(asset: asset, track: track).enumerated() where i == index {
            let rendered = try renderer.render(frame: frame, correction: matrix_identity_float3x3, crop: CGRect(origin: .zero, size: size), outputSize: target)
            let gray = OutputMotion.gray(of: rendered)
            let w = OutputMotion.width, h = OutputMotion.height
            var gradient = 0.0
            for y in 0..<(h - 1) { for x in 0..<(w - 1) {
                let p = gray[y * w + x]
                gradient += Double(abs(p - gray[y * w + x + 1]) + abs(p - gray[(y + 1) * w + x]))
            } }
            return (Double(gray.reduce(0, +)) / Double(gray.count), gradient / Double((w - 1) * (h - 1) * 2))
        }
        return (0, 0)
    }

    static func summary(_ rows: [Row]) -> String {
        let total = rows.reduce(0) { $0 + $1.failures }
        let affected = rows.filter { $0.failures > 0 }
        var rules: [String: Int] = [:]
        for row in rows { for (rule, n) in row.byRule { rules[rule, default: 0] += n } }
        func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
        var out = "\(rows.count) clips, \(total) rejected frames in \(affected.count) clips\n"
        out += "by rule: " + rules.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") + "\n"
        let heavy = rows.filter { $0.failures >= 3 }
        out += "clips with 3 or more rejected: \(heavy.count)\n"
        out += String(format: "median brightness: all clips %.0f, clips with 3+ rejected %.0f\n", median(rows.map(\.meanLuma)), median(heavy.map(\.meanLuma)))
        out += String(format: "median detail:     all clips %.1f, clips with 3+ rejected %.1f\n", median(rows.map(\.detail)), median(heavy.map(\.detail)))
        out += String(format: "median frame rate: all clips %.1f, clips with 3+ rejected %.1f\n", median(rows.map(\.frameRate)), median(heavy.map(\.frameRate)))
        out += "\n| failures | frames | rules | brightness | detail | fps | size |\n| ---: | ---: | --- | ---: | ---: | ---: | --- |\n"
        for row in heavy.sorted(by: { $0.failures > $1.failures }) {
            out += String(format: "| %d | %d | %@ | %.0f | %.1f | %.0f | %dx%d |\n", row.failures, row.frames,
                          row.byRule.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "),
                          row.meanLuma, row.detail, row.frameRate, row.width, row.height)
        }
        return out
    }
}


/// An EXPERIMENT, harness only: shows the estimator the frames the way they looked before the color fix (#90).
/// Before it, every frame handed to the estimator had been written without naming a color space, which stored
/// linear-light values as if they were sRGB, so the picture was darkened by roughly gamma 2.2. Re-rendering a
/// correct frame the same way reproduces that, which lets the effect on the estimator be measured on its own.
struct DarkenedEstimator: MotionEstimator {
    let inner: any MotionEstimator
    private static let context = CIContext()

    func estimate(frame: CVPixelBuffer, reference: CVPixelBuffer) async throws -> FrameMotion {
        try await inner.estimate(frame: try Self.darkened(frame), reference: try Self.darkened(reference))
    }

    static func darkened(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let out = try StabilizedRenderer.makeScratchBuffer(width: width, height: height)
        context.render(CIImage(cvPixelBuffer: buffer), to: out, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return out
    }
}
