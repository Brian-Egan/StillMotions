/// Export size presets (PRD §1.1): the long edge, in pixels, of the output.
public enum SizePreset: String, Codable, CaseIterable, Sendable {
    case small
    case medium
    case full

    /// `nil` means native: the crop's own size, never upscaled.
    public var longEdge: Int? {
        switch self {
        case .small: return 480
        case .medium: return 720
        case .full: return nil
        }
    }
}
