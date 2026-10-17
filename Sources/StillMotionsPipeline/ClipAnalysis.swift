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
    /// The stabilization mode this path was solved for.
    public let mode: StabilizationMode
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
    /// What was judged: the numbers `assessment` reads. Residual motion is in here only for Locked.
    public let metrics: ClipMetrics
    /// Residual motion as measured, when it was (Smooth and Locked, and only where optical flow
    /// runs). Informational for Smooth: that mode keeps slow camera drift on purpose, and the meter
    /// counts drift as motion, so the 1 px limit that fits a still camera does not fit it.
    public let measuredResidualMotion: Double?

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
        mode: StabilizationMode = .default,
        solver: (any CameraPathSolver)? = nil,
        masker: SubjectMasker? = nil,
        residualMotion: ((CameraPath) async throws -> Double?)? = nil,
        onStage: ((String, Double) -> Void)? = nil,
        renderer: StabilizedRenderer = StabilizedRenderer()
    ) async throws -> ClipAnalysis {
        let start = ContinuousClock.now
        let motion = try await estimateMotion(
            movieURL: movieURL, referenceIndex: referenceIndex, estimator: estimator,
            strategy: strategy, masker: masker, renderer: renderer
        )
        let elapsed = ContinuousClock.now - start
        onStage?("estimate", Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        return try await analyze(
            movieURL: movieURL, motion: motion, mode: mode, solver: solver,
            residualMotion: residualMotion, onStage: onStage, renderer: renderer
        )
    }

    /// The same analysis from motion that has already been estimated. Changing stabilization mode
    /// is this call with a different `mode`: estimation, the slow part, is not repeated.
    ///
    /// `solver` overrides the mode's own solver (for tests and experiments).
    public static func analyze(
        movieURL: URL,
        motion: MotionResult,
        mode: StabilizationMode = .default,
        solver: (any CameraPathSolver)? = nil,
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

        let chosenSolver = solver ?? mode.solver
        var path: CameraPath
        var stabilized = true
        var reason: String?
        do {
            path = try await timed("solve") { try chosenSolver.solve(motion: motion.motion, frameSize: motion.size) }
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

        // Off does not try to steady anything, so its residual motion is not measured. Smooth keeps
        // slow drift on purpose, so its residual is measured but not judged. Only Locked, which aims
        // for a still camera, is judged on it. The loop seam is measured in every mode.
        let residual = mode == .off ? nil : try await timed("residualMotion") { try await residualMotion?(path) }

        let metrics = ClipMetrics(
            cropRetention: stabilized ? path.cropRetention : 0,
            residualMotion: stabilized && mode == .locked ? residual : nil,
            loopSeamRatio: loop?.seamRatio
        )
        return ClipAnalysis(
            motion: motion, mode: mode, path: path, stabilized: stabilized, unstabilizedReason: reason, loop: loop,
            metrics: metrics, measuredResidualMotion: stabilized ? residual : nil
        )
    }
}
