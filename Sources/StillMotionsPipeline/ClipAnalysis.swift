import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import simd

/// Everything the analysis half of the pipeline learned about one clip, including whether the
/// stabilization worked. The harness and the editor both get their verdict from `assessment`,
/// which is computed once here, so the two cannot disagree (PRD R-22).
public struct ClipAnalysis {
    public let motion: ClipAnalyzer.MotionResult
    /// The solved camera path. When the clip could not be stabilized at all (`stabilized` is false)
    /// this is the UNSTABILIZED path: identity corrections and the whole frame as the crop, so a
    /// caller can still preview and export the clip as shot.
    public let path: CameraPath
    /// False when the frames share no common area to crop to (or a frame's transform could not be
    /// inverted), so no stabilized view exists. `unstabilizedReason` says why.
    public let stabilized: Bool
    public let unstabilizedReason: String?
    /// The chosen loop, or nil when none was found (a clip too short to search).
    public let loop: LoopSelection?
    public let metrics: ClipMetrics

    /// Whether stabilization worked, with the measured value of each signal. A RESULT, not an
    /// error: a failing clip is still usable and still exportable (PRD R-18).
    public var assessment: StabilizationAssessment { metrics.assessment }
}

extension ClipAnalyzer {
    /// Estimates motion, solves the camera path, picks a loop and judges the result.
    ///
    /// Never throws because a clip is HARD to stabilize: a clip with nothing to crop to comes back
    /// with `stabilized == false`, the unstabilized path, and a crop-retention reading of 0, so the
    /// caller can warn and carry on. It throws only when the clip cannot be read at all.
    ///
    /// - Parameters:
    ///   - residualMotion: measures residual motion on the solved path, or returns nil when it
    ///     cannot. Residual motion needs optical flow, which ships only in the harness (decision
    ///     0001), so the app passes nil and that signal is simply "not measured".
    ///   - onStage: called with the name and duration (ms) of each stage, for instrumentation.
    public static func analyze(
        movieURL: URL,
        referenceIndex: Int,
        estimator: any MotionEstimator,
        strategy: Strategy = .chained,
        solver: any CameraPathSolver = WarpToReferenceSolver(),
        masker: SubjectMasker? = nil,
        residualMotion: ((CameraPath) async throws -> Double?)? = nil,
        onStage: ((String, Double) -> Void)? = nil,
        renderer: StabilizedRenderer = StabilizedRenderer()
    ) async throws -> ClipAnalysis {
        func timed<T>(_ stage: String, _ work: () async throws -> T) async rethrows -> T {
            let start = ContinuousClock.now
            defer {
                let elapsed = ContinuousClock.now - start
                onStage?(stage, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
            }
            return try await work()
        }

        let motion = try await timed("estimate") {
            try await estimateMotion(
                movieURL: movieURL, referenceIndex: referenceIndex, estimator: estimator,
                strategy: strategy, masker: masker, renderer: renderer
            )
        }

        var path: CameraPath
        var stabilized = true
        var reason: String?
        do {
            path = try await timed("solve") { try solver.solve(motion: motion.motion, frameSize: motion.size) }
        } catch let error as CameraPathError {
            // No common area, or an uninvertible frame: nothing to crop to. Not an error for the
            // caller; the clip is reported as failing and can still be shown as shot.
            stabilized = false
            reason = error.description
            path = CameraPath(
                corrections: Array(repeating: matrix_identity_float3x3, count: motion.motion.count),
                crop: CGRect(origin: .zero, size: motion.size), cropRetention: 0
            )
        }

        // Loop selection runs on signatures of the frames as a viewer will see them.
        let loop: LoopSelection? = try await timed("loopSelection") {
            let signatures = try await signatures(movieURL: movieURL, path: path, renderer: renderer)
            let outcome = try? LoopSelector.select(
                signatures: signatures, frameRate: motion.frameRate, mode: .loop, frameTimes: motion.frameTimes
            )
            if case .selected(let selection)? = outcome { return selection }
            return nil
        }

        let residual = try await timed("residualMotion") { try await residualMotion?(path) }

        let metrics = ClipMetrics(
            cropRetention: stabilized ? path.cropRetention : 0,
            residualMotion: stabilized ? residual : nil,
            loopSeamRatio: loop?.seamRatio
        )
        return ClipAnalysis(
            motion: motion, path: path, stabilized: stabilized, unstabilizedReason: reason, loop: loop, metrics: metrics
        )
    }
}
