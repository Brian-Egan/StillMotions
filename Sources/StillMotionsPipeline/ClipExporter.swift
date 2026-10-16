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
        // The source's own frame times: real Live Photo video is variable frame rate, and a file
        // timestamped at the nominal rate would play it at the wrong speed.
        let times = try FrameSequence.presentationTimes(asset: asset, track: track)
        let frames = try FrameSequence.make(asset: asset, track: track)
        let outputSize = OutputSize.size(forCrop: path.crop, longEdge: preset.longEdge)
        let nextFrame = try renderer.makeProducer(
            frames: frames, corrections: path.corrections, crop: path.crop, outputSize: outputSize
        )
        return try await encoder.encode(
            nextFrame: nextFrame, frameRate: frameRate, mode: mode,
            frameTimes: times.count == path.corrections.count ? times : nil, to: url
        )
    }

    /// Decodes `movieURL`, stabilizes it with `path`, renders at `preset`'s size, decimates to
    /// `frameRate`, and writes a GIF to `url`.
    ///
    /// - `trim` limits the export to a range of source frames (default: the whole clip).
    /// - `loop`, with Loop mode, exports the chosen loop with its crossfade (from `LoopSelector`)
    ///   in place of `trim`. Without it, Loop mode repeats exactly the frames it is given.
    public static func exportGIF(
        movieURL: URL,
        path: CameraPath,
        preset: SizePreset,
        frameRate: GifFrameRate,
        mode: PlaybackMode,
        trim: Range<Int>? = nil,
        loop: LoopSelection? = nil,
        to url: URL,
        renderer: StabilizedRenderer = StabilizedRenderer(),
        encoder: GifEncoder = GifEncoder()
    ) async throws -> GifEncodingResult {
        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.noVideoTrack(movieURL)
        }
        let sourceRate = Double(try await track.load(.nominalFrameRate))
        let outputSize = OutputSize.size(forCrop: path.crop, longEdge: preset.longEdge)
        // Output ticks pick the source frame nearest in TIME, so the GIF lasts as long as the clip
        // even when the source is variable frame rate. Falls back to the nominal rate only if the
        // times do not line up with the frames.
        let decodedTimes = try FrameSequence.presentationTimes(asset: asset, track: track)
        let times: [Double]? = decodedTimes.count == path.corrections.count ? decodedTimes : nil

        if mode == .loop, let loop {
            let nextFrame = try loopProducer(
                asset: asset, track: track, path: path, loop: loop, frameRate: frameRate,
                sourceRate: sourceRate, frameTimes: times, outputSize: outputSize, renderer: renderer
            )
            return try await encoder.encode(nextFrame: nextFrame, frameRate: frameRate, mode: mode, to: url)
        }

        let range = trim ?? 0..<path.corrections.count
        let chosen = times.map { frameRate.sourceIndices(frameTimes: Array($0[range])) }
            ?? frameRate.sourceIndices(sourceCount: range.count, sourceRate: sourceRate)
        let kept = chosen.map { $0 + range.lowerBound }
        let frames = SelectedFrames(source: try FrameSequence.make(asset: asset, track: track), indices: kept)
        let nextFrame = try renderer.makeProducer(
            frames: frames, corrections: kept.map { path.corrections[$0] },
            crop: path.crop, outputSize: outputSize
        )
        return try await encoder.encode(nextFrame: nextFrame, frameRate: frameRate, mode: mode, to: url)
    }

    /// Frames of a chosen loop, in playback order, with its crossfade applied.
    ///
    /// The first few frames of a loop are blends of footage from the START of the loop and from
    /// AFTER its return frame, which is late in the source. Decoding only runs forward, so those
    /// few frames are rendered and blended up front (a handful of buffers, held), and the rest of
    /// the loop then streams in order.
    static func loopProducer(
        asset: AVAsset, track: AVAssetTrack, path: CameraPath, loop: LoopSelection,
        frameRate: GifFrameRate, sourceRate: Double, frameTimes: [Double]? = nil, outputSize: CGSize, renderer: StabilizedRenderer
    ) throws -> () throws -> CVPixelBuffer? {
        // Positions within the loop that survive decimation to the GIF rate, by the frames' real
        // times when known.
        let positions = frameTimes.map { frameRate.sourceIndices(frameTimes: Array($0[loop.startIndex..<loop.returnIndex])) }
            ?? frameRate.sourceIndices(sourceCount: loop.length, sourceRate: sourceRate)
        let recipes = positions.map { loop.frames[$0] }

        // Which source frames the blends need, rendered in one forward pass.
        let blendSources = Set(recipes.flatMap { recipe -> [Int] in
            recipe.secondary.map { [recipe.primary, $0] } ?? []
        })
        var rendered: [Int: CVPixelBuffer] = [:]
        if let last = blendSources.max() {
            var index = 0
            for frame in try FrameSequence.make(asset: asset, track: track) {
                if blendSources.contains(index) {
                    rendered[index] = try renderer.render(
                        frame: frame, correction: path.corrections[index], crop: path.crop, outputSize: outputSize
                    )
                }
                if index == last { break }
                index += 1
            }
        }
        var blended: [CVPixelBuffer] = []
        for recipe in recipes {
            guard let secondary = recipe.secondary, let a = rendered[recipe.primary], let b = rendered[secondary] else { continue }
            blended.append(try renderer.blend(a, b, weight: recipe.secondaryWeight))
        }

        // Plain frames, streamed in source order. Blended positions come first in the loop (they
        // are its first frames), so they are emitted before these.
        let plain = recipes.filter { $0.secondary == nil }.map(\.primary)
        let frames = SelectedFrames(source: try FrameSequence.make(asset: asset, track: track), indices: plain)
        let rest = try renderer.makeProducer(
            frames: frames, corrections: plain.map { path.corrections[$0] },
            crop: path.crop, outputSize: outputSize
        )
        var pendingBlends = blended[...]
        return {
            if let first = pendingBlends.popFirst() { return first }
            return try rest()
        }
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
