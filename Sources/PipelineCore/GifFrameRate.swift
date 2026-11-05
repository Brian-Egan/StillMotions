/// GIF frame rates (PRD §1.1, decision 0014). A GIF stores each frame's delay in whole centiseconds,
/// so a rate is exact only when its frame time is a whole number of them: 16.67 fps is 6 cs, 20 fps is
/// 5 cs, 25 fps is 4 cs. 30 fps is 3.33 cs, which no single delay can hold: a flat 3 cs plays about 11%
/// fast (it is what Google's MotionStills wrote). 30 fps is offered anyway, written with a mix of 3 and
/// 4 cs delays that averages 3.33, so the clip still plays at the speed it was shot (`delaysWritten`).
public enum GifFrameRate: String, Codable, CaseIterable, Sendable {
    case fps16_67
    case fps20
    case fps25
    case fps30

    /// The average time each frame is shown, in centiseconds: 6, 5, 4, and 3.33 for 30 fps.
    public var averageCentiseconds: Double {
        switch self {
        case .fps16_67: return 6
        case .fps20: return 5
        case .fps25: return 4
        case .fps30: return 10.0 / 3
        }
    }

    public var framesPerSecond: Double {
        switch self {
        case .fps30: return 30
        default: return 100.0 / averageCentiseconds
        }
    }

    /// The delays a GIF at this rate is written with. One value for the rates whose frame time is a whole
    /// number of centiseconds. For 30 fps the two values 3 and 4, in a repeating 3, 4, 3 (gifski rounds the
    /// running total of frame times, not each delay, so the error never builds up).
    public var delaysWritten: [Int] {
        switch self {
        case .fps30: return [3, 4]
        default: return [Int(averageCentiseconds.rounded())]
        }
    }

    /// When frame `index` starts, in seconds, handed to the encoder as its presentation time. For the
    /// whole-centisecond rates this is an exact multiple of a centisecond, as it has always been.
    public func presentationTime(ofFrame index: Int) -> Double {
        switch self {
        case .fps30: return Double(index) / 30
        default: return Double(index) * averageCentiseconds / 100
        }
    }

    /// Which of `sourceCount` frames shot at `sourceRate` to keep at this rate: for each output
    /// tick, the nearest source frame. A 3 s, 30 fps clip at 20 fps is 60 frames.
    public func sourceIndices(sourceCount: Int, sourceRate: Double) -> [Int] {
        guard sourceCount > 0, sourceRate > 0 else { return [] }
        let duration = Double(sourceCount) / sourceRate
        let outputCount = max(1, Int((duration * framesPerSecond).rounded(.down)))
        return (0..<outputCount).map { tick in
            min(sourceCount - 1, Int((Double(tick) * sourceRate / framesPerSecond + 0.5).rounded(.down)))
        }
    }

    /// The same selection for a clip with real frame times (variable frame rate): output tick `k`
    /// is at `k / fps`, and gets the source frame whose time is nearest. The GIF then plays for as
    /// long as the clip does, which index-based decimation does not when frames are unevenly spaced.
    /// For evenly spaced times this returns what `sourceIndices(sourceCount:sourceRate:)` does.
    public func sourceIndices(frameTimes: [Double]) -> [Int] {
        let relative = FrameTiming.relative(frameTimes)
        guard !relative.isEmpty else { return [] }
        let duration = FrameTiming.duration(of: relative)
        guard duration > 0 else { return [0] }
        // The tiny nudge keeps an exact whole number of ticks (3 s at 20 fps) from rounding down
        // to one fewer through floating-point noise.
        let outputCount = max(1, Int((duration * framesPerSecond + 1e-9).rounded(.down)))
        return (0..<outputCount).map { tick in
            FrameTiming.nearestIndex(to: Double(tick) / framesPerSecond, in: relative)
        }
    }
}
