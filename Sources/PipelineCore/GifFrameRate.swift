/// GIF frame rates (PRD §1.1). A GIF stores each frame's delay in whole centiseconds, so only
/// rates whose frame time is a whole number of centiseconds play at the right speed:
/// 30 fps is 3.33 cs and would be stored as 3 cs, about 11% fast; 15 fps (6.67 cs) is the same
/// problem. These three are the exact ones in a useful range.
public enum GifFrameRate: String, Codable, CaseIterable, Sendable {
    case fps16_67
    case fps20
    case fps25

    /// Each frame's display time, in centiseconds.
    public var centiseconds: Int {
        switch self {
        case .fps16_67: return 6
        case .fps20: return 5
        case .fps25: return 4
        }
    }

    public var framesPerSecond: Double { 100.0 / Double(centiseconds) }

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
}
