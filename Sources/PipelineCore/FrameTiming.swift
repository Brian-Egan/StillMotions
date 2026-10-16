import Foundation

/// Real frame times, for clips that are not constant frame rate.
///
/// A Live Photo's video is variable frame rate: the median clip averages about 29 fps but more than
/// a quarter average below 24, and low light is slower still. Anything that assumes frame `i` is at
/// `i / rate` plays such a clip at the wrong speed, so the stages that care about duration take the
/// frames' presentation times instead, in seconds.
///
/// Every function here reduces to the constant-rate answer when the times are evenly spaced, which
/// is what keeps the constant-rate synthetic fixtures' output unchanged.
public enum FrameTiming {
    /// Times shifted so the first frame is at 0. Empty in, empty out.
    public static func relative(_ times: [Double]) -> [Double] {
        guard let first = times.first else { return [] }
        return times.map { $0 - first }
    }

    /// How long the clip plays: from the first frame to the end of the last, taking the last frame
    /// to last as long as the gap before it. A constant-rate clip of `n` frames is `n / rate`.
    /// `relativeTimes` must be from `relative(_:)`.
    public static func duration(of relativeTimes: [Double]) -> Double {
        guard let last = relativeTimes.last else { return 0 }
        guard relativeTimes.count >= 2 else { return last }
        return last + (last - relativeTimes[relativeTimes.count - 2])
    }

    /// The index of the frame nearest `time`. When two frames are equally near (a tie to within
    /// floating-point noise) the LATER one wins, matching the constant-rate "round half up".
    public static func nearestIndex(to time: Double, in relativeTimes: [Double]) -> Int {
        guard !relativeTimes.isEmpty else { return 0 }
        // First index whose time is >= `time`.
        var low = 0, high = relativeTimes.count
        while low < high {
            let mid = (low + high) / 2
            if relativeTimes[mid] < time { low = mid + 1 } else { high = mid }
        }
        if low == 0 { return 0 }
        if low == relativeTimes.count { return relativeTimes.count - 1 }
        let before = time - relativeTimes[low - 1]
        let after = relativeTimes[low] - time
        return after <= before + 1e-9 ? low : low - 1
    }
}
