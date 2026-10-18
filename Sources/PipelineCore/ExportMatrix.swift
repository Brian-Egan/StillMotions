/// Which formats each playback mode can be exported as (PRD R-10, decision 0005).
///
/// |        | GIF | MP4 |
/// | ------ | --- | --- |
/// | Loop   | yes | no  |
/// | Bounce | yes | yes |
/// | Once   | yes | yes |
///
/// Loop is GIF-only because no looping flag exists in MP4 that Apple platforms honour: a looping
/// MP4 would play once when it is shared. The UI shows `reason` rather than silently greying MP4
/// out, because a disabled control with no explanation reads as a bug.
public enum ExportMatrix {
    public static func isAllowed(format: ExportFormat, mode: PlaybackMode) -> Bool {
        !(format == .mp4 && mode == .loop)
    }

    /// One line saying why `format` cannot be used with `mode`, or nil when it can.
    public static func reason(format: ExportFormat, mode: PlaybackMode) -> String? {
        isAllowed(format: format, mode: mode) ? nil : "MP4 can't loop when shared. Use GIF."
    }

    /// The format to use after the mode changes: the current one when it still works, GIF when it
    /// does not (an MP4 selection followed by choosing Loop).
    public static func format(_ current: ExportFormat, afterSelecting mode: PlaybackMode) -> ExportFormat {
        isAllowed(format: current, mode: mode) ? current : .gif
    }
}
