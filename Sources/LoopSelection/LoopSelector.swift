import Foundation
import PipelineCore

/// How the search behaves. Defaults are the PRD's (R-8, §1.2).
public struct LoopSelectionConfig: Equatable {
    /// Fraction of the clip, at each end, that candidate frames may come from. The loop
    /// starts in the first `windowFraction` and its return frame is in the last.
    public var windowFraction: Double
    /// Shortest loop kept, in seconds. Stops the search returning a two-frame loop that
    /// happens to match perfectly.
    public var minimumDuration: Double
    /// Frames over which the start of the loop is blended with the footage that followed
    /// the return frame. 0 turns the crossfade off.
    public var crossfadeFrames: Int

    public init(windowFraction: Double = 0.3, minimumDuration: Double = 1.0, crossfadeFrames: Int = 3) {
        self.windowFraction = windowFraction
        self.minimumDuration = minimumDuration
        self.crossfadeFrames = crossfadeFrames
    }
}

/// One output frame of a loop: a source frame, optionally mixed with a second.
public struct LoopFrameRecipe: Equatable, Sendable {
    public let primary: Int
    public let secondary: Int?
    /// How much of `secondary` to mix in, 0...1. 0 when `secondary` is nil.
    public let secondaryWeight: Float

    public init(primary: Int, secondary: Int?, secondaryWeight: Float) {
        self.primary = primary
        self.secondary = secondary
        self.secondaryWeight = secondaryWeight
    }
}

public struct LoopSelection: Equatable, Sendable {
    /// First frame of the loop.
    public let startIndex: Int
    /// The frame that matches `startIndex`. It is NOT part of the loop: playback goes
    /// `startIndex ..< returnIndex` and then jumps back, so the jump lands where the clip
    /// would have gone next. (Including it would show the same picture twice at the seam.)
    public let returnIndex: Int
    public var length: Int { returnIndex - startIndex }
    /// One entry per output frame, in playback order.
    public let frames: [LoopFrameRecipe]
    /// Seam difference over the median consecutive-frame difference, with no crossfade.
    public let seamRatioBeforeCrossfade: Double
    /// The same, after the crossfade. This is the PRD's loop-seam metric (<= 1.5 passes).
    public let seamRatio: Double
    /// Median mean-absolute-difference between consecutive frames of the loop.
    public let medianStep: Double

    public init(
        startIndex: Int, returnIndex: Int, frames: [LoopFrameRecipe],
        seamRatioBeforeCrossfade: Double, seamRatio: Double, medianStep: Double
    ) {
        self.startIndex = startIndex
        self.returnIndex = returnIndex
        self.frames = frames
        self.seamRatioBeforeCrossfade = seamRatioBeforeCrossfade
        self.seamRatio = seamRatio
        self.medianStep = medianStep
    }
}

public enum LoopOutcome: Equatable {
    /// Bounce and Once have no seam, so no search ran.
    case skipped(PlaybackMode)
    case selected(LoopSelection)
}

public enum LoopSelectionError: Error, CustomStringConvertible, Equatable {
    case tooFewFrames(Int)
    case invalidFrameRate(Double)

    public var description: String {
        switch self {
        case .tooFewFrames(let count):
            return "loop selection needs at least 3 frames, got \(count)"
        case .invalidFrameRate(let rate):
            return "frame rate \(rate) is not positive"
        }
    }
}

public enum LoopSelector {
    /// Differences below this (half an 8-bit gray level) are invisible, so they are not
    /// allowed to make a ratio's denominator tiny. Without it a perfectly static clip would
    /// score noise against noise.
    static let noiseFloor = 1.0 / 512.0

    /// Finds the pair of frames, one near each end, that look most alike, and returns the loop
    /// between them with a short crossfade. `signatures` are of the STABILIZED, cropped
    /// frames: that is what a viewer sees, so that is what has to match.
    ///
    /// `frameTimes` are the frames' presentation times in seconds, one per signature. Pass them for
    /// real (variable frame rate) clips: the minimum loop length is then measured in seconds, not
    /// counted in frames at a nominal rate, and the start window is the first `windowFraction` of
    /// the clip's time. Without them frames are assumed evenly spaced at `frameRate`. For evenly
    /// spaced times both give the same answer.
    public static func select(
        signatures: [FrameSignature],
        frameRate: Double,
        mode: PlaybackMode,
        config: LoopSelectionConfig = LoopSelectionConfig(),
        frameTimes: [Double]? = nil
    ) throws -> LoopOutcome {
        guard mode == .loop else { return .skipped(mode) }
        guard frameRate > 0 else { throw LoopSelectionError.invalidFrameRate(frameRate) }
        let count = signatures.count
        guard count >= 3 else { throw LoopSelectionError.tooFewFrames(count) }

        let times = frameTimes.flatMap { $0.count == count ? FrameTiming.relative($0) : nil }
        let minimumLength = max(2, Int((config.minimumDuration * frameRate).rounded(.up)))
        // The crossfade reads `crossfadeFrames` frames from the return frame onward.
        let fade = max(0, config.crossfadeFrames)
        let lastReturn = max(1, count - max(fade, 1))
        let windowFrames: Int
        if let times {
            // Frames inside the first `windowFraction` of the clip's playing time; the end window
            // uses the same number of frames.
            let limit = FrameTiming.duration(of: times) * config.windowFraction - 1e-9
            windowFrames = max(1, times.filter { $0 < limit }.count)
        } else {
            windowFrames = max(1, Int((Double(count) * config.windowFraction).rounded(.up)))
        }
        let startCandidates = 0..<min(windowFrames, count)
        let firstReturn = max(1, count - windowFrames)
        let returnCandidates = firstReturn <= lastReturn ? Array(firstReturn...lastReturn) : []

        var best: (start: Int, returnIndex: Int, difference: Double)?
        for start in startCandidates {
            for returnIndex in returnCandidates where Self.longEnough(start: start, returnIndex: returnIndex, minimumLength: minimumLength, minimumDuration: config.minimumDuration, times: times) {
                let difference = signatures[start].difference(to: signatures[returnIndex])
                // Strict `<` keeps the earliest pair on a tie; among pairs with the same
                // difference that is the longest loop at that start.
                if best == nil || difference < best!.difference { best = (start, returnIndex, difference) }
            }
        }
        // Nothing satisfies the minimum (a very short clip): fall back to the longest loop
        // the clip allows rather than failing.
        if best == nil {
            let returnIndex = lastReturn
            best = (0, returnIndex, signatures[0].difference(to: signatures[returnIndex]))
        }
        let (start, returnIndex, _) = best!
        let faded = makeSelection(signatures: signatures, start: start, returnIndex: returnIndex, fade: fade)
        // A crossfade only earns its place by lowering the seam. When the two ends already
        // match to within noise, blending adds nothing, so leave the frames untouched.
        if fade > 0, faded.seamRatio >= faded.seamRatioBeforeCrossfade {
            return .selected(makeSelection(signatures: signatures, start: start, returnIndex: returnIndex, fade: 0))
        }
        return .selected(faded)
    }

    /// A loop from `start` to `returnIndex` plays for the time between those two frames. With real
    /// frame times that is what is compared with the minimum duration; the small tolerance keeps a
    /// loop of exactly the minimum from failing on floating-point noise.
    static func longEnough(start: Int, returnIndex: Int, minimumLength: Int, minimumDuration: Double, times: [Double]?) -> Bool {
        guard let times else { return returnIndex - start >= minimumLength }
        return returnIndex - start >= 2 && times[returnIndex] - times[start] >= minimumDuration - 1e-6
    }

    static func makeSelection(signatures: [FrameSignature], start: Int, returnIndex: Int, fade: Int) -> LoopSelection {
        let length = returnIndex - start
        // The crossfade blends the first frames of the loop with the footage after the
        // return frame: output frame j is mostly `returnIndex + j` and fades into
        // `start + j`. So the jump from the last frame lands on a frame that is the natural
        // continuation of it, and the picture has settled into the loop proper by frame `fade`.
        let fadeFrames = max(0, min(fade, length - 1, signatures.count - returnIndex))
        var frames: [LoopFrameRecipe] = []
        for offset in 0..<length {
            if offset < fadeFrames {
                let weight = Float(offset + 1) / Float(fadeFrames + 1)
                // `weight` of the loop's own frame, the rest from the continuation.
                frames.append(LoopFrameRecipe(primary: returnIndex + offset, secondary: start + offset, secondaryWeight: weight))
            } else {
                frames.append(LoopFrameRecipe(primary: start + offset, secondary: nil, secondaryWeight: 0))
            }
        }

        let steps = (start..<(returnIndex - 1)).map { signatures[$0].difference(to: signatures[$0 + 1]) }.sorted()
        let median = steps.isEmpty ? 0 : steps[steps.count / 2]
        let denominator = max(median, noiseFloor)

        let last = signatures[returnIndex - 1]
        let before = last.difference(to: signatures[start])
        let first = signature(of: frames[0], in: signatures)
        let after = last.difference(to: first)
        return LoopSelection(
            startIndex: start,
            returnIndex: returnIndex,
            frames: frames,
            seamRatioBeforeCrossfade: before / denominator,
            seamRatio: after / denominator,
            medianStep: median
        )
    }

    static func signature(of recipe: LoopFrameRecipe, in signatures: [FrameSignature]) -> FrameSignature {
        guard let secondary = recipe.secondary else { return signatures[recipe.primary] }
        return signatures[recipe.primary].blended(with: signatures[secondary], weight: recipe.secondaryWeight)
    }
}
