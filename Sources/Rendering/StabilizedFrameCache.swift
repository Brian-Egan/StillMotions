import CoreImage
import CoreVideo
import Foundation
import simd

/// The stabilized frames, rendered once at preview resolution and then read cheaply
/// (ARCHITECTURE §5). It holds WHOLE stabilized frames, not cropped ones, so the editor's cheap
/// interactions never re-render: a crop is a sub-rectangle read, a trim is an index range, and
/// a frame-rate change is a decimated read.
///
/// Memory is the cost: a 3 s clip at 720 px long edge is about 100 to 140 MB of BGRA. That is
/// by design (the preview needs random access), and is separate from the streaming path used
/// for export, whose memory is flat.
public final class StabilizedFrameCache {
    /// Pixel size of every cached frame.
    public let frameSize: CGSize
    /// Cached pixels per source pixel (`frameSize.width / sourceSize.width`).
    public let scale: Double
    public private(set) var frames: [CVPixelBuffer] = []
    /// How many frames this cache has rendered. Reads never change it, which is what a test
    /// checks to prove they do not re-render.
    public private(set) var renderCount = 0

    public var count: Int { frames.count }

    public init(frameSize: CGSize, scale: Double) {
        self.frameSize = frameSize
        self.scale = scale
    }

    /// Renders every frame of `frames`, stabilized and uncropped, at `longEdge` pixels on the
    /// long side, one at a time. This is the one expensive step; call it once per solve.
    public static func build<Frames: Sequence>(
        frames: Frames,
        corrections: [simd_float3x3],
        sourceSize: CGSize,
        longEdge: Int = 720,
        renderer: StabilizedRenderer = StabilizedRenderer()
    ) throws -> StabilizedFrameCache where Frames.Element == CVPixelBuffer {
        let scale = Double(longEdge) / Double(max(sourceSize.width, sourceSize.height))
        // Plain rounding, not even dimensions: this is for display, and rounding 405 down to 404
        // would squash the picture slightly.
        let size = CGSize(width: (sourceSize.width * scale).rounded(), height: (sourceSize.height * scale).rounded())
        let cache = StabilizedFrameCache(frameSize: size, scale: Double(size.width) / Double(sourceSize.width))
        let whole = CGRect(origin: .zero, size: sourceSize)
        var index = 0
        for frame in frames {
            guard index < corrections.count else {
                throw RenderingError.countMismatch(frames: index + 1, corrections: corrections.count)
            }
            // Each cached frame is its own buffer (the cache keeps them), unlike the pooled
            // streaming path.
            let rendered = try renderer.render(frame: frame, correction: corrections[index], crop: whole, outputSize: size)
            cache.frames.append(rendered)
            cache.renderCount += 1
            index += 1
        }
        return cache
    }

    /// O(1): the stored buffer.
    public func frame(at index: Int) -> CVPixelBuffer {
        frames[index]
    }

    /// O(1): a slice of the stored buffers, not a copy.
    public func frames(in range: Range<Int>) -> ArraySlice<CVPixelBuffer> {
        frames[range]
    }

    /// A sub-rectangle of one frame, given in SOURCE pixel coordinates (e.g. `CameraPath.crop`),
    /// as an image that is a lazy view onto the cached buffer. Nothing is rendered until it is
    /// drawn, and the cache itself is untouched.
    public func image(at index: Int, sourceRect: CGRect) -> CIImage {
        let rect = CGRect(
            x: sourceRect.minX * scale, y: sourceRect.minY * scale,
            width: sourceRect.width * scale, height: sourceRect.height * scale
        )
        return CIImage(cvPixelBuffer: frames[index]).cropped(to: rect)
    }
}

/// Output sizing shared by the preview cache and the encoders (#15, #16).
public enum OutputSize {
    /// Integer width and height, each rounded to the nearest integer and then down to even (HEVC and most decoders
    /// want even dimensions), never below 2.
    public static func evenSize(width: Double, height: Double) -> CGSize {
        // Round first (479.99999 is 480), then clear the low bit.
        CGSize(width: max(2, Int(width.rounded()) & ~1), height: max(2, Int(height.rounded()) & ~1))
    }

    /// The size of a crop at a size preset: `longEdge` pixels on the long side, or the crop's
    /// own size (native) when `longEdge` is nil, keeping the crop's aspect ratio. Never upscales.
    public static func size(forCrop crop: CGRect, longEdge: Int?) -> CGSize {
        let nativeLong = Double(max(crop.width, crop.height))
        guard let longEdge, Double(longEdge) < nativeLong else {
            return evenSize(width: Double(crop.width), height: Double(crop.height))
        }
        let scale = Double(longEdge) / nativeLong
        return evenSize(width: Double(crop.width) * scale, height: Double(crop.height) * scale)
    }
}
