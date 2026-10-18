import CoreGraphics
import Foundation

/// Turns the editor's current choices into a size estimate (PRD R-12, R-13), without encoding
/// anything. The export screen calls this for every preset on every settings change, so it must stay
/// cheap: it is arithmetic over numbers the editor already holds.
public enum ExportSizing {
    /// Frames the export will contain.
    ///
    /// GIF: the playback plan's steps. That is the preview's frame list, which a test holds equal to
    /// what the exporter writes, and it includes the Loop crossfade, Bounce and the rate decimation.
    /// MP4: every source frame (an MP4 is written at the clip's own rate), and Bounce plays them
    /// forward then back without repeating the turning frame, `2n - 1`.
    public static func frameCount(
        format: ExportFormat, mode: PlaybackMode, gifRate: GifFrameRate, frameTimes: [Double], loop: LoopSelection?
    ) -> Int {
        switch format {
        case .gif:
            return PlaybackPlan.make(mode: mode, frameTimes: frameTimes, loop: loop, frameRate: gifRate).steps.count
        case .mp4:
            let n = frameTimes.count
            return mode == .bounce ? max(0, 2 * n - 1) : n
        }
    }

    /// The estimator's input for one set of export choices.
    public static func input(
        format: ExportFormat, preset: SizePreset, sizes: PresetSizes = .standard, mode: PlaybackMode, gifRate: GifFrameRate,
        path: CameraPath, frameTimes: [Double], loop: LoopSelection?, sourceFrameRate: Double, content: ContentFeatures?
    ) -> SizeInput {
        let size = OutputSize.size(forCrop: path.crop, longEdge: sizes.longEdge(for: preset))
        return SizeInput(
            format: format, width: Int(size.width), height: Int(size.height),
            frameCount: frameCount(format: format, mode: mode, gifRate: gifRate, frameTimes: frameTimes, loop: loop),
            gifRate: gifRate, sourceFrameRate: sourceFrameRate, cropRetention: path.cropRetention,
            isBounce: mode == .bounce, content: content
        )
    }

    /// Estimated bytes for one set of export choices.
    public static func estimate(
        format: ExportFormat, preset: SizePreset, sizes: PresetSizes = .standard, mode: PlaybackMode, gifRate: GifFrameRate,
        path: CameraPath, frameTimes: [Double], loop: LoopSelection?, sourceFrameRate: Double, content: ContentFeatures?,
        estimator: SizeEstimator = SizeEstimator()
    ) -> Int {
        estimator.estimate(input(
            format: format, preset: preset, sizes: sizes, mode: mode, gifRate: gifRate, path: path, frameTimes: frameTimes,
            loop: loop, sourceFrameRate: sourceFrameRate, content: content
        ))
    }
}
