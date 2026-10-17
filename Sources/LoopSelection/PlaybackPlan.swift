import Foundation
import PipelineCore

/// One frame of playback: a source frame, optionally mixed with a second (the loop crossfade).
public struct PlaybackStep: Equatable, Sendable {
    public let primary: Int
    public let secondary: Int?
    /// How much of `secondary` to mix in, 0...1. 0 when `secondary` is nil.
    public let secondaryWeight: Float

    public init(primary: Int, secondary: Int? = nil, secondaryWeight: Float = 0) {
        self.primary = primary
        self.secondary = secondary
        self.secondaryWeight = secondaryWeight
    }
}

/// What the editor plays, in what order, at what rate: a pure function of the analysis, the mode
/// and the frame rate. Nothing here touches pixels, which is why switching mode or frame rate is
/// instant and never re-solves (ARCHITECTURE §5): it only re-plans over frames already rendered.
///
/// It decimates the way the exporters do (`GifFrameRate.sourceIndices(frameTimes:)`, bounce
/// mirrored after decimation, loop recipes picked by position), so the preview shows what an export
/// will produce. A test holds that: the plan's step count equals a real export's frame count.
public struct PlaybackPlan: Equatable, Sendable {
    /// In playback order, already decimated to `frameRate`.
    public let steps: [PlaybackStep]
    public let frameRate: GifFrameRate

    /// Seconds each step is shown.
    public var stepDuration: Double { 1.0 / frameRate.framesPerSecond }
    /// Seconds one pass takes.
    public var duration: Double { Double(steps.count) * stepDuration }

    public init(steps: [PlaybackStep], frameRate: GifFrameRate) {
        self.steps = steps
        self.frameRate = frameRate
    }

    /// The step shown `seconds` into playback. The preview repeats forever, in every mode, so
    /// Once plays one pass and then starts again.
    public func step(atElapsed seconds: Double) -> PlaybackStep? {
        guard !steps.isEmpty else { return nil }
        // The nudge keeps a time exactly on a step edge (0.05 s at 20 fps) from rounding down to the
        // step before, through floating-point noise.
        let index = Int((max(seconds, 0) / stepDuration + 1e-9).rounded(.down)) % steps.count
        return steps[index]
    }

    /// - Parameters:
    ///   - frameTimes: each source frame's presentation time (a Live Photo is variable frame rate).
    ///   - loop: the selected loop, or nil when none was found (a clip too short to search), in
    ///     which case Loop mode plays the whole clip.
    public static func make(
        mode: PlaybackMode,
        frameTimes: [Double],
        loop: LoopSelection?,
        frameRate: GifFrameRate
    ) -> PlaybackPlan {
        guard !frameTimes.isEmpty else { return PlaybackPlan(steps: [], frameRate: frameRate) }
        let wholeClip = frameRate.sourceIndices(frameTimes: frameTimes).map { PlaybackStep(primary: $0) }

        switch mode {
        case .once:
            return PlaybackPlan(steps: wholeClip, frameRate: frameRate)
        case .bounce:
            // Forward, then back without repeating the turnaround frame: n becomes 2n - 1.
            return PlaybackPlan(steps: wholeClip + wholeClip.dropLast().reversed(), frameRate: frameRate)
        case .loop:
            guard let loop else { return PlaybackPlan(steps: wholeClip, frameRate: frameRate) }
            let positions = frameRate.sourceIndices(frameTimes: Array(frameTimes[loop.startIndex..<loop.returnIndex]))
            let steps = positions.map { position -> PlaybackStep in
                let recipe = loop.frames[position]
                return PlaybackStep(primary: recipe.primary, secondary: recipe.secondary, secondaryWeight: recipe.secondaryWeight)
            }
            return PlaybackPlan(steps: steps, frameRate: frameRate)
        }
    }
}
