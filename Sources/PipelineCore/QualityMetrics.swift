import Foundation

/// The PRD §1.2 thresholds. Changing one needs a decision record, because the harness
/// baseline depends on them.
public enum QualityThresholds {
    /// Crop retention must be at least this fraction of the original frame area.
    public static let minimumCropRetention = 0.60
    /// Mean residual displacement of background features between consecutive output frames,
    /// in pixels at output resolution, must be below this.
    public static let maximumResidualMotion = 1.0
    /// Loop seam difference over the median consecutive-frame difference, at most this.
    public static let maximumLoopSeamRatio = 1.5
}

/// The three signals that decide whether a clip's stabilization failed (PRD R-12, R-22).
public enum FailureSignal: String, Codable, CaseIterable, Sendable {
    case cropRetention
    case residualMotion
    case loopSeam
}

/// What was measured for one clip. The harness verdict and the editor's warning both come from
/// `failures`, so they cannot disagree (PRD R-22).
public struct ClipMetrics: Codable, Equatable, Sendable {
    public var cropRetention: Double
    /// `nil` when residual motion was not measured.
    public var residualMotion: Double?
    /// `nil` when no loop was selected (Bounce and Once have no seam).
    public var loopSeamRatio: Double?

    public init(cropRetention: Double, residualMotion: Double? = nil, loopSeamRatio: Double? = nil) {
        self.cropRetention = cropRetention
        self.residualMotion = residualMotion
        self.loopSeamRatio = loopSeamRatio
    }

    /// The signals this clip fails. A signal that was not measured is not a failure.
    public var failures: [FailureSignal] {
        var failed: [FailureSignal] = []
        if cropRetention < QualityThresholds.minimumCropRetention { failed.append(.cropRetention) }
        if let residualMotion, residualMotion >= QualityThresholds.maximumResidualMotion { failed.append(.residualMotion) }
        if let loopSeamRatio, loopSeamRatio > QualityThresholds.maximumLoopSeamRatio { failed.append(.loopSeam) }
        return failed
    }

    public var passed: Bool { failures.isEmpty }
}
