import Foundation

/// The committed regression baseline (`harness/baseline.json`, PRD §1.4). CI only ever sees the
/// synthetic fixtures, so this guards correctness, not real-world quality (PRD R-23).
public struct Baseline: Codable, Equatable {
    public struct Clip: Codable, Equatable {
        public var cropRetention: Double
        public var residualMotion: Double?
        public var loopSeamRatio: Double?
        /// Passed all three thresholds when the baseline was written.
        public var passed: Bool

        public init(_ metrics: ClipMetrics) {
            cropRetention = metrics.cropRetention
            residualMotion = metrics.residualMotion
            loopSeamRatio = metrics.loopSeamRatio
            passed = metrics.passed
        }
    }

    /// Keyed by clip name.
    public var clips: [String: Clip]
    public var estimator: String
    public var solver: String
    /// Which residual-motion meter produced the residual values (for example `flow-veryHigh`).
    /// Residual readings depend on the flow accuracy level (the zero-motion noise floor at 720 px is
    /// about 0.28 px at `.medium` and 0.16 px at `.veryHigh`), so a baseline is only comparable to a
    /// run that measures the same way. Nil in a baseline written before this was recorded (#72).
    public var residualMeter: String?

    public init(clips: [String: ClipMetrics], estimator: String, solver: String, residualMeter: String? = nil) {
        self.clips = clips.mapValues(Clip.init)
        self.estimator = estimator
        self.solver = solver
        self.residualMeter = residualMeter
    }

    public static func load(from url: URL) throws -> Baseline {
        try JSONDecoder().decode(Baseline.self, from: Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

/// PRD §1.4: a change fails the regression check if, against the baseline,
///
/// 1. median crop retention drops by more than 2 percentage points, or
/// 2. median residual motion rises by more than 10%, or
/// 3. any clip that previously passed all three thresholds now fails one.
///
/// The third is the important one: medians hide a single clip going badly wrong, and per-clip
/// regressions are what a user actually notices. Medians are taken over the clips present in
/// BOTH the baseline and the current run, so adding or removing a clip cannot move them.
public enum RegressionCheck {
    public static let allowedCropRetentionDrop = 0.02
    public static let allowedResidualMotionRise = 0.10
    /// "More than" must not trip on the last bit of floating-point error (0.85 - 0.83 is not
    /// exactly 0.02).
    static let epsilon = 1e-9

    /// One human-readable line per violated condition; empty means no regression.
    ///
    /// `residualMeter` names how this run measured residual motion. When it differs from the one
    /// the baseline was written with (or the baseline does not say), the residual medians are not
    /// comparable, so this reports that plainly instead of comparing them, and the rest of the
    /// check still runs.
    public static func compare(baseline: Baseline, current: [String: ClipMetrics], residualMeter: String? = nil) -> [String] {
        var problems: [String] = []
        var residualsComparable = true
        if let residualMeter, baseline.residualMeter != residualMeter {
            residualsComparable = false
            problems.append(
                "the baseline measured residual motion with '\(baseline.residualMeter ?? "an unrecorded meter")' but this run uses '\(residualMeter)': "
                    + "residual values are not comparable. Rewrite the baseline with --update-baseline (#72)"
            )
        }

        let missing = baseline.clips.keys.filter { current[$0] == nil }.sorted()
        for name in missing {
            problems.append("clip '\(name)' is in the baseline but was not produced by this run")
        }

        let common = baseline.clips.keys.filter { current[$0] != nil }.sorted()
        guard !common.isEmpty else { return problems }

        let baselineCrop = median(common.map { baseline.clips[$0]!.cropRetention })
        let currentCrop = median(common.map { current[$0]!.cropRetention })
        if baselineCrop - currentCrop > allowedCropRetentionDrop + epsilon {
            problems.append(String(
                format: "median crop retention fell from %.1f%% to %.1f%% (allowed drop: %.0f points)",
                baselineCrop * 100, currentCrop * 100, allowedCropRetentionDrop * 100
            ))
        }

        let baselineResidual = common.compactMap { baseline.clips[$0]!.residualMotion }
        let currentResidual = common.compactMap { current[$0]!.residualMotion }
        if residualsComparable, !baselineResidual.isEmpty, !currentResidual.isEmpty {
            let before = median(baselineResidual), after = median(currentResidual)
            if after > before * (1 + allowedResidualMotionRise) + epsilon {
                problems.append(String(
                    format: "median residual motion rose from %.3f px to %.3f px (allowed rise: %.0f%%)",
                    before, after, allowedResidualMotionRise * 100
                ))
            }
        }

        for name in common where baseline.clips[name]!.passed {
            let failed = current[name]!.failures
            if !failed.isEmpty {
                problems.append("clip '\(name)' passed in the baseline and now fails: \(failed.map(\.rawValue).joined(separator: ", "))")
            }
        }
        return problems
    }

    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
