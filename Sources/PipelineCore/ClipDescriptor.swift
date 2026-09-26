import Foundation

/// What the importer (PRD R-4) knows about a clip before any pipeline stage runs.
///
/// Durations and rates are `Double` seconds/fps rather than `CMTime`, because
/// `PipelineCore` stays within Foundation/CoreVideo/CoreGraphics/simd — no CoreMedia. The
/// importer, which does depend on AVFoundation, converts.
public struct ClipDescriptor: Equatable {
    public let width: Int
    public let height: Int
    public let frameCount: Int
    /// The source video's nominal frame rate, in frames per second.
    public let sourceFrameRate: Double
    public let duration: Double
    /// Index of the frame nearest the Live Photo's key-photo timestamp — the default
    /// reference frame for motion estimation (PRD R-4, R-5).
    public let referenceFrameIndex: Int

    public init(
        width: Int,
        height: Int,
        frameCount: Int,
        sourceFrameRate: Double,
        duration: Double,
        referenceFrameIndex: Int
    ) {
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.sourceFrameRate = sourceFrameRate
        self.duration = duration
        self.referenceFrameIndex = referenceFrameIndex
    }
}
