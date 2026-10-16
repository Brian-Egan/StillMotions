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

    /// Decodes `movieURL`, stabilizes it with `path`, renders at `preset`'s size, decimates to
    /// `frameRate`, and writes a GIF to `url`.
    ///
    /// `trim` limits the export to a range of source frames (default: the whole clip). Loop
    /// mode repeats exactly the frames it is given: choosing loop points and crossfading the
    /// seam happens upstream (`LoopSelector`), and the harness (#17) wires that in.
    public static func exportGIF(
        movieURL: URL,
        path: CameraPath,
        preset: SizePreset,
        frameRate: GifFrameRate,
        mode: PlaybackMode,
        trim: Range<Int>? = nil,
        to url: URL,
        renderer: StabilizedRenderer = StabilizedRenderer(),
        encoder: GifEncoder = GifEncoder()
    ) async throws -> GifEncodingResult {
        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.noVideoTrack(movieURL)
        }
        let sourceRate = Double(try await track.load(.nominalFrameRate))
        let range = trim ?? 0..<path.corrections.count
        let kept = frameRate
            .sourceIndices(sourceCount: range.count, sourceRate: sourceRate)
            .map { $0 + range.lowerBound }

        let frames = SelectedFrames(source: try FrameSequence.make(asset: asset, track: track), indices: kept)
        let outputSize = OutputSize.size(forCrop: path.crop, longEdge: preset.longEdge)
        let nextFrame = try renderer.makeProducer(
            frames: frames, corrections: kept.map { path.corrections[$0] },
            crop: path.crop, outputSize: outputSize
        )
        return try await encoder.encode(nextFrame: nextFrame, frameRate: frameRate, mode: mode, to: url)
    }
}

/// The frames of `source` at `indices` (ascending), in that order. An index that repeats yields
/// the same frame again, which is what a source slower than the output rate needs. Frames in
/// between are decoded and dropped, because decoding only runs forward.
struct SelectedFrames<Source: Sequence>: Sequence where Source.Element == CVPixelBuffer {
    let source: Source
    let indices: [Int]

    func makeIterator() -> Iterator {
        Iterator(source: source.makeIterator(), indices: indices)
    }

    struct Iterator: IteratorProtocol {
        var source: Source.Iterator
        let indices: [Int]
        var emitted = 0
        var position = -1
        var current: CVPixelBuffer?

        init(source: Source.Iterator, indices: [Int]) {
            self.source = source
            self.indices = indices
        }

        mutating func next() -> CVPixelBuffer? {
            guard emitted < indices.count else { return nil }
            let wanted = indices[emitted]
            while position < wanted {
                guard let frame = source.next() else { return nil }
                position += 1
                current = frame
            }
            emitted += 1
            return current
        }
    }
}
