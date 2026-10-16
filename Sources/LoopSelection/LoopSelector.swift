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
public struct LoopFrameRecipe: Equatable {
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

public struct LoopSelection: Equatable {
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
    public static func select(
        signatures: [FrameSignature],
        frameRate: Double,
        mode: PlaybackMode,
        config: LoopSelectionConfig = LoopSelectionConfig()
    ) throws -> LoopOutcome {
        guard mode == .loop else { return .skipped(mode) }
        guard frameRate > 0 else { throw LoopSelectionError.invalidFrameRate(frameRate) }
        let count = signatures.count
        guard count >= 3 else { throw LoopSelectionError.tooFewFrames(count) }

        let minimumLength = max(2, Int((config.minimumDuration * frameRate).rounded(.up)))
        // The crossfade reads `crossfadeFrames` frames from the return frame onward.
        let fade = max(0, config.crossfadeFrames)
        let lastReturn = max(1, count - max(fade, 1))
        let windowFrames = max(1, Int((Double(count) * config.windowFraction).rounded(.up)))
        let startCandidates = 0..<min(windowFrames, count)
        let firstReturn = max(1, count - windowFrames)
        let returnCandidates = firstReturn <= lastReturn ? Array(firstReturn...lastReturn) : []

        var best: (start: Int, returnIndex: Int, difference: Double)?
        for start in startCandidates {
            for returnIndex in returnCandidates where returnIndex - start >= minimumLength {
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
