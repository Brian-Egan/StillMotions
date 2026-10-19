/// The long-edge pixel sizes of the Small and Medium export presets (PRD §1.1). Full is native by
/// definition and has no number. The developer wanted these editable, so a size that turns out wrong
/// can be changed without a rebuild (issue #34).
public struct PresetSizes: Equatable, Sendable {
    public var small: Int
    public var medium: Int

    /// The PRD's values.
    public static let standard = PresetSizes(small: 480, medium: 720)

    /// What a typed value may be: a typo cannot produce a nonsensical export.
    public static let allowedRange = 240...1920

    public init(small: Int, medium: Int) {
        self.small = small
        self.medium = medium
    }

    /// The long edge for `preset`: its pixel size, or nil for Full (native).
    public func longEdge(for preset: SizePreset) -> Int? {
        switch preset {
        case .small: return small
        case .medium: return medium
        case .full: return nil
        }
    }

    /// One size that was changed, or a reason it was not accepted.
    public enum Edit: Equatable, Sendable {
        case accepted
        /// The value was changed to `value` and why.
        case adjusted(to: Int, reason: String)
    }

    /// Sets Small to `requested`, clamped into the allowed range and kept below Medium. Returns what
    /// happened, so the screen can say why a typed number was changed instead of silently ignoring it.
    public mutating func setSmall(_ requested: Int) -> Edit {
        let ceiling = min(Self.allowedRange.upperBound, medium - 10)
        let value = max(Self.allowedRange.lowerBound, min(ceiling, requested))
        small = value
        return Self.describe(requested: requested, applied: value, floorNote: "Small must be at least \(Self.allowedRange.lowerBound) px", ceilingNote: "Small must be smaller than Medium (\(medium) px)", ceilingIsRange: ceiling == Self.allowedRange.upperBound)
    }

    /// Sets Medium to `requested`, clamped into the allowed range and kept above Small.
    public mutating func setMedium(_ requested: Int) -> Edit {
        let floor = max(Self.allowedRange.lowerBound, small + 10)
        let value = max(floor, min(Self.allowedRange.upperBound, requested))
        medium = value
        return Self.describe(requested: requested, applied: value, floorNote: "Medium must be larger than Small (\(small) px)", ceilingNote: "Medium can be at most \(Self.allowedRange.upperBound) px", ceilingIsRange: true)
    }

    private static func describe(requested: Int, applied: Int, floorNote: String, ceilingNote: String, ceilingIsRange: Bool) -> Edit {
        guard requested != applied else { return .accepted }
        return .adjusted(to: applied, reason: (requested < applied ? floorNote : ceilingNote) + ". Set to \(applied) px.")
    }

    /// A pair read back from storage: out-of-range or out-of-order values fall back to the standard
    /// ones, so a bad stored value cannot produce a nonsensical export.
    public static func validated(small: Int?, medium: Int?) -> PresetSizes {
        guard let small, let medium, allowedRange.contains(small), allowedRange.contains(medium), small < medium else { return .standard }
        return PresetSizes(small: small, medium: medium)
    }
}
