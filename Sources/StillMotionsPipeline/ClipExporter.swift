import AVFoundation
import CoreVideo
import Foundation

/// Wires decode, stabilization, rendering and encoding together for one export. This is the
/// single path the harness and (later) the app use, so what the harness measures is what ships
/// (ARCHITECTURE §2).
public enum ClipExporter {
    /// Decodes `movieURL`, stabilizes it with `path`, renders at `preset`'s size, and writes an
    /// HEVC MP4 to `url`. Loop mode throws `VideoEncodingError.loopNotSupported`.
    public static func exportVideo(
        movieURL: URL,
        path: CameraPath,
        preset: SizePreset,
        mode: PlaybackMode,
        to url: URL,
        renderer: StabilizedRenderer = StabilizedRenderer(),
        encoder: VideoEncoder = VideoEncoder()
    ) async throws -> VideoEncodingResult {
        // Refuse before doing any decoding work.
        guard mode != .loop else { throw VideoEncodingError.loopNotSupported }

        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.noVideoTrack(movieURL)
        }
        let frameRate = Double(try await track.load(.nominalFrameRate))
        let frames = try FrameSequence.make(asset: asset, track: track)
        let outputSize = OutputSize.size(forCrop: path.crop, longEdge: preset.longEdge)
        let nextFrame = try renderer.makeProducer(
            frames: frames, corrections: path.corrections, crop: path.crop, outputSize: outputSize
        )
        return try await encoder.encode(nextFrame: nextFrame, frameRate: frameRate, mode: mode, to: url)
    }
}
