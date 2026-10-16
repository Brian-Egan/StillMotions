import Foundation

/// The file formats an export can produce (PRD R-10, R-11).
public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case gif
    case mp4
}

/// The user's default export choices (PRD R-19, §1.1). Every default below is the PRD's, and
/// `ExportDefaultsTests` pins each one so a change here is a deliberate edit, not an accident.
public struct ExportDefaults: Equatable, Sendable {
    /// Medium (720 px) deliberately equals the preview cache resolution, so exporting it needs no
    /// re-render from source.
    public var sizePreset: SizePreset = .medium
    /// 20 fps is exactly 5 centiseconds, which GIF can store; see `GifFrameRate`.
    public var gifFrameRate: GifFrameRate = .fps20
    public var mode: PlaybackMode = .loop
    /// GIF is the only format that loops in iMessage, the primary destination (decision 0005).
    public var format: ExportFormat = .gif

    public init() {}
}

/// Persists `ExportDefaults` in `UserDefaults`. Plain and deliberately boring: four strings under
/// one prefix, no persistence framework.
///
/// Each field is read on its own. A value that is missing, or that this build no longer
/// recognizes, falls back to that field's default and leaves the others alone, so renaming a case
/// later cannot wipe a user's other choices.
public struct ExportDefaultsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix: String

    /// - Parameters:
    ///   - defaults: `.standard` in the app; a throwaway suite in tests.
    ///   - prefix: namespaces the keys.
    public init(defaults: UserDefaults = .standard, prefix: String = "exportDefaults.") {
        self.defaults = defaults
        self.prefix = prefix
    }

    public func load() -> ExportDefaults {
        var result = ExportDefaults()
        if let value: SizePreset = read("sizePreset") { result.sizePreset = value }
        if let value: GifFrameRate = read("gifFrameRate") { result.gifFrameRate = value }
        if let value: PlaybackMode = read("mode") { result.mode = value }
        if let value: ExportFormat = read("format") { result.format = value }
        return result
    }

    public func save(_ values: ExportDefaults) {
        defaults.set(values.sizePreset.rawValue, forKey: key("sizePreset"))
        defaults.set(values.gifFrameRate.rawValue, forKey: key("gifFrameRate"))
        defaults.set(values.mode.rawValue, forKey: key("mode"))
        defaults.set(values.format.rawValue, forKey: key("format"))
    }

    /// Forgets every stored choice, so `load()` returns the PRD defaults again.
    public func reset() {
        for name in ["sizePreset", "gifFrameRate", "mode", "format"] { defaults.removeObject(forKey: key(name)) }
    }

    private func key(_ name: String) -> String { prefix + name }

    private func read<Value: RawRepresentable>(_ name: String) -> Value? where Value.RawValue == String {
        defaults.string(forKey: key(name)).flatMap(Value.init(rawValue:))
    }
}
