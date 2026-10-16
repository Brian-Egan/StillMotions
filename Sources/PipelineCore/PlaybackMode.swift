/// How a stabilized clip is played back (PRD R-9).
public enum PlaybackMode: String, Codable, CaseIterable, Sendable {
    /// Trimmed to the best loop points and crossfaded. GIF only (decision 0005).
    case loop
    /// Forward, then reversed.
    case bounce
    /// A single pass.
    case once
}
