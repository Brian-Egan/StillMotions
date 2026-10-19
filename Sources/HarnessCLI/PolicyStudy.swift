import AVFoundation
import Foundation
import StillMotionsPipeline

/// `stillmotions-harness policy-study --fixtures <dir> --out <dir>` (issue #98).
///
/// For every clip: how much of the frame people cover, and how the PICTURE moves (`OutputMotion`) under
/// each stabilization when the motion is estimated without and with people masked out. It is the
/// evidence for a rule like "mask people when they are prominent": which clips it helps, which it
/// hurts, and what the threshold on person coverage should be. Output jitter is measured on the
/// rendered frames, so it can see estimator errors that the solver's own poses cannot.
enum PolicyStudy {
    struct Outcome: Codable {
        let cropKept: Double?          // nil when no crop exists (the solver found no common region)
        let jitter: Double?
        let netPan: Double?
    }
    struct Row: Codable {
        let clip: String
        let personCoverage: Double
        let frames: Int
        let off: Outcome
        let unmasked: [String: Outcome]
        let masked: [String: Outcome]
        let estimateSecondsUnmasked: Double
        let estimateSecondsMasked: Double
        let estimationFailuresUnmasked: Int
        let estimationFailuresMasked: Int
    }

    /// The stabilizations compared, by name.
    static var solvers: [(name: String, solver: any CameraPathSolver)] { [
        ("locked", WarpToReferenceSolver()),
        ("smooth-8", SmoothedPathSolver(sigmaFrames: 8)),
        ("smooth-12", SmoothedPathSolver()),   // the shipped strength
        ("smooth-16", SmoothedPathSolver(sigmaFrames: 16)),
    ] }

    static func run(arguments: [String]) async throws {
        var fixtures: URL?, out: URL?
        var limit: Int?, every = 1
        var withMasking = true
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--fixtures": i += 1; fixtures = URL(fileURLWithPath: arguments[i], isDirectory: true)
            case "--out": i += 1; out = URL(fileURLWithPath: arguments[i], isDirectory: true)
            case "--limit": i += 1; limit = Int(arguments[i])
            case "--no-masked": withMasking = false
            case "--every": i += 1; every = max(1, Int(arguments[i]) ?? 1)
            default: throw SpikeError("unknown argument '\(arguments[i])'\nusage: stillmotions-harness policy-study --fixtures <dir> --out <dir> [--limit N]")
            }
            i += 1
        }
        guard let fixtures, let out else { throw SpikeError("--fixtures and --out are required") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var clips = try ClipLocator.find(in: fixtures)
        if every > 1 { clips = clips.enumerated().filter { $0.offset % every == 0 }.map(\.element) }
        if let limit { clips = Array(clips.prefix(limit)) }

        var rows: [Row] = []
        for (index, clip) in clips.enumerated() {
            do {
                let row = try await study(clip: clip, withMasking: withMasking)
                rows.append(row)
                print(String(format: "[%d/%d] %@ people %.0f%%  off %.2f | smooth-8 %@ -> %@",
                             index + 1, clips.count, clip.name, row.personCoverage * 100, row.off.jitter ?? -1,
                             describe(row.unmasked["smooth-8"]), describe(row.masked["smooth-8"])))
                if (index + 1) % 10 == 0 { try save(rows, to: out) }
            } catch {
                print("[\(index + 1)/\(clips.count)] \(clip.name): FAILED (\(error))")
            }
        }
        try save(rows, to: out)
    }

    static func describe(_ outcome: PolicyStudy.Outcome?) -> String {
        guard let outcome, let crop = outcome.cropKept, let jitter = outcome.jitter else { return "n/a" }
        return String(format: "%.0f%%/%.2f", crop * 100, jitter)
    }

    static func save(_ rows: [Row], to out: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: out.appendingPathComponent("rows.json"))
    }

    static func study(clip: ClipInput, withMasking: Bool = true) async throws -> Row {
        let renderer = StabilizedRenderer()
        let masker = SubjectMasker(configuration: .init(analysisLongEdge: 360, usesForegroundInstances: false))
        let referenceIndex = try await clip.referenceIndex()

        // How much of the frame people cover, on the reference frame.
        let asset = AVURLAsset(url: clip.movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SpikeError("no video track") }
        var coverage = 0.0
        for (index, frame) in try FrameSequence.make(asset: asset, track: track).enumerated() where index == referenceIndex {
            coverage = (try? await masker.mask(for: frame).rawCoverage) ?? 0
            break
        }

        func estimate(masked: Bool) async throws -> (ClipAnalyzer.MotionResult, Double) {
            let start = ContinuousClock.now
            let motion = try await ClipAnalyzer.estimateMotion(
                movieURL: clip.movieURL, referenceIndex: referenceIndex, estimator: VisionRegistrationEstimator(),
                strategy: .chained, masker: masked ? masker : nil, renderer: renderer
            )
            let elapsed = ContinuousClock.now - start
            return (motion, Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
        }
        let (plain, plainSeconds) = try await estimate(masked: false)
        // Masked estimates are the expensive part; `--no-masked` skips them and reports the unmasked motion twice.
        let (masked, maskedSeconds) = withMasking ? try await estimate(masked: true) : (plain, 0)

        let off = try await ReferenceCompare.measure(
            clip: clip, corrections: Array(repeating: matrix_identity_float3x3, count: plain.motion.count),
            crop: CGRect(origin: .zero, size: plain.size), times: plain.frameTimes, renderer: renderer
        )

        func outcomes(for motion: ClipAnalyzer.MotionResult) async -> [String: Outcome] {
            var result: [String: Outcome] = [:]
            for (name, solver) in solvers {
                guard let path = try? solver.solve(motion: motion.motion, frameSize: motion.size),
                      let measured = try? await ReferenceCompare.measure(
                        clip: clip, corrections: path.corrections, crop: path.crop, times: motion.frameTimes, renderer: renderer
                      )
                else { result[name] = Outcome(cropKept: nil, jitter: nil, netPan: nil); continue }
                result[name] = Outcome(cropKept: path.cropRetention, jitter: measured.jitter, netPan: measured.netPan)
            }
            return result
        }

        return Row(
            clip: clip.name, personCoverage: coverage, frames: plain.motion.count,
            off: Outcome(cropKept: 1, jitter: off.jitter, netPan: off.netPan),
            unmasked: await outcomes(for: plain), masked: withMasking ? await outcomes(for: masked) : [:],
            estimateSecondsUnmasked: plainSeconds, estimateSecondsMasked: maskedSeconds,
            estimationFailuresUnmasked: plain.estimationFailures, estimationFailuresMasked: masked.estimationFailures
        )
    }
}
