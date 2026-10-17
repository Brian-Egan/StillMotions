/// How strongly a clip is stabilized. The three modes differ only in the camera path the footage is
/// steered toward, so motion is estimated once and changing mode only re-solves the path.
public enum StabilizationMode: String, Codable, CaseIterable, Sendable {
    /// Frames as shot, whole frame, no crop.
    case off
    /// The shake removed and slow drift kept, so less of the frame is lost to cropping.
    case smooth
    /// The camera pinned to the reference frame, like a tripod. The largest crop.
    case locked

    /// What the editor starts in.
    public static let `default` = StabilizationMode.locked

    public var displayName: String {
        switch self {
        case .off: return "Off"
        case .smooth: return "Smooth"
        case .locked: return "Locked"
        }
    }
}
