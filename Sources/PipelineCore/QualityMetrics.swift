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

    /// The full verdict, with the measured value of every signal. This is the single place the
    /// thresholds are applied: `failures` and `passed` come from it, the harness reports it, and the
    /// editor's warning reads it, so they cannot disagree (PRD R-22).
    public var assessment: StabilizationAssessment { StabilizationAssessment(metrics: self) }

    /// The signals this clip fails. A signal that was not measured is not a failure.
    public var failures: [FailureSignal] { assessment.failedSignals }

    public var passed: Bool { failures.isEmpty }
}

/// One signal's measurement, its limit, and whether it failed.
public struct SignalReading: Codable, Equatable, Sendable {
    public let signal: FailureSignal
    /// What was measured. `nil` when the signal was not measured: residual motion is measured
    /// only where optical flow runs (the harness), and a loop seam only when a loop was selected.
    public let value: Double?
    /// The PRD §1.2 limit this value is judged against.
    public let limit: Double
    /// True when measured and past the limit. An unmeasured signal is never a failure.
    public let failed: Bool

    /// How the limit applies: crop retention must stay at or above it, residual motion must stay
    /// below it, and the loop seam must not exceed it.
    public var direction: String {
        switch signal {
        case .cropRetention: return "at least"
        case .residualMotion: return "below"
        case .loopSeam: return "at most"
        }
    }
}

/// Whether a clip's stabilization worked, as a RESULT rather than an error: a failing clip is still
/// usable and still exportable (PRD R-18 makes the warning non-blocking), so nothing here throws.
///
/// Always holds one reading per signal, in `FailureSignal.allCases` order, each carrying its
/// measured value, so a caller can show "crop 43% (needs at least 60%)" and not only "failed".
///
/// `inlierRatio` is deliberately NOT an input. It is `nil` when the shipping estimator is
/// registration (decision 0001), and a signal that is sometimes unavailable cannot gate a
/// user-facing warning.
public struct StabilizationAssessment: Codable, Equatable, Sendable {
    public let readings: [SignalReading]

    public init(metrics: ClipMetrics) {
        readings = [
            SignalReading(
                signal: .cropRetention, value: metrics.cropRetention, limit: QualityThresholds.minimumCropRetention,
                failed: metrics.cropRetention < QualityThresholds.minimumCropRetention
            ),
            SignalReading(
                signal: .residualMotion, value: metrics.residualMotion, limit: QualityThresholds.maximumResidualMotion,
                failed: metrics.residualMotion.map { $0 >= QualityThresholds.maximumResidualMotion } ?? false
            ),
            SignalReading(
                signal: .loopSeam, value: metrics.loopSeamRatio, limit: QualityThresholds.maximumLoopSeamRatio,
                failed: metrics.loopSeamRatio.map { $0 > QualityThresholds.maximumLoopSeamRatio } ?? false
            ),
        ]
    }

    public var failedSignals: [FailureSignal] { readings.filter(\.failed).map(\.signal) }
    public var isFailure: Bool { readings.contains { $0.failed } }

    public func reading(for signal: FailureSignal) -> SignalReading {
        readings.first { $0.signal == signal }!
    }
}
