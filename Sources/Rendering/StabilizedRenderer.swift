import CoreImage
import CoreVideo
import Foundation
import simd

public enum RenderingError: Error, CustomStringConvertible {
    case invalidOutputSize(CGSize)
    case invalidCrop(CGRect)
    case bufferAllocationFailed(width: Int, height: Int)
    case countMismatch(frames: Int, corrections: Int)

    public var description: String {
        switch self {
        case .invalidOutputSize(let size): return "output size \(size.width)x\(size.height) is not positive"
        case .invalidCrop(let rect): return "crop rectangle \(rect) is empty"
        case .bufferAllocationFailed(let w, let h): return "could not allocate a \(w)x\(h) pixel buffer"
        case .countMismatch(let f, let c): return "\(f) frames but \(c) corrections"
        }
    }
}

/// Applies a stabilizing correction and a crop to source frames, at any output size.
///
/// Core Image, not Metal: it is the obvious implementation (PRD R-25) and the measured cost
/// leaves a wide margin against the preview budget (numbers are in the #14 PR). Coordinates
/// are Core Image's (origin at the BOTTOM-left), the same space the motion estimators and
/// `CameraPath.crop` use.
public final class StabilizedRenderer: @unchecked Sendable {
    private let context: CIContext

    public init(context: CIContext = CIContext()) {
        self.context = context
    }

    /// One stabilized, cropped frame.
    ///
    /// - Parameters:
    ///   - correction: `CameraPath.corrections[i]`, mapping this frame onto the reference.
    ///   - crop: a rectangle in reference coordinates, e.g. `CameraPath.crop`, or the whole
    ///     frame to get an uncropped stabilized frame (what the preview cache stores).
    ///   - outputSize: integer pixel size of the result; the crop is scaled to fill it.
    ///   - clampEdges: replicate the frame's border pixels outward, so a crop that grazes the
    ///     frame edge never shows a dark fringe. Turn off to see out-of-frame areas as
    ///     transparent, which is how tests check for black edges.
    public func render(
        frame: CVPixelBuffer,
        correction: simd_float3x3,
        crop: CGRect,
        outputSize: CGSize,
        clampEdges: Bool = true,
        into destination: CVPixelBuffer? = nil
    ) throws -> CVPixelBuffer {
        guard outputSize.width >= 1, outputSize.height >= 1 else { throw RenderingError.invalidOutputSize(outputSize) }
        guard crop.width > 0, crop.height > 0 else { throw RenderingError.invalidCrop(crop) }
        let width = Int(outputSize.width.rounded()), height = Int(outputSize.height.rounded())

        // Crop, then scale it to fill the output.
        let cropToOutput = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            .concatenating(CGAffineTransform(scaleX: CGFloat(width) / crop.width, y: CGFloat(height) / crop.height))

        var image = CIImage(cvPixelBuffer: frame).samplingLinear()
        if let affine = correction.affineTransform {
            // One combined transform, so the frame is resampled once, not twice. The
            // high-quality downsample path matters when shrinking to a small output size:
            // plain bilinear aliases fine texture badly.
            if clampEdges { image = image.clampedToExtent() }
            image = image.transformed(by: affine.concatenating(cropToOutput), highQualityDownsample: true)
        } else {
            image = Self.perspective(image, by: correction)
            if clampEdges { image = image.clampedToExtent() }
            image = image.transformed(by: cropToOutput, highQualityDownsample: true)
        }
        image = image.cropped(to: CGRect(x: 0, y: 0, width: width, height: height))

        let target = try destination ?? Self.makeBuffer(width: width, height: height)
        context.render(image, to: target, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return target
    }

    /// Streams `frames` through `render`, handing each result to `body` before touching the
    /// next. Output buffers come from a small pool and are REUSED, so `body` must be done with
    /// the buffer (encoded, copied, hashed) by the time it returns; peak memory is then flat
    /// however long the clip is.
    public func renderStream<Frames: Sequence>(
        frames: Frames,
        corrections: [simd_float3x3],
        crop: CGRect,
        outputSize: CGSize,
        body: (_ index: Int, _ frame: CVPixelBuffer) throws -> Void
    ) throws where Frames.Element == CVPixelBuffer {
        let width = Int(outputSize.width.rounded()), height = Int(outputSize.height.rounded())
        guard width >= 1, height >= 1 else { throw RenderingError.invalidOutputSize(outputSize) }
        let pool = try Self.makePool(width: width, height: height)
        var index = 0
        for frame in frames {
            guard index < corrections.count else {
                throw RenderingError.countMismatch(frames: index + 1, corrections: corrections.count)
            }
            var pooled: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pooled)
            guard let destination = pooled else { throw RenderingError.bufferAllocationFailed(width: width, height: height) }
            let rendered = try render(
                frame: frame, correction: corrections[index], crop: crop,
                outputSize: outputSize, into: destination
            )
            try body(index, rendered)
            index += 1
        }
    }

    // MARK: - Helpers

    static func makeBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &out)
        guard let buffer = out else { throw RenderingError.bufferAllocationFailed(width: width, height: height) }
        return buffer
    }

    static func makePool(width: Int, height: Int) throws -> CVPixelBufferPool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &pool)
        guard let pool else { throw RenderingError.bufferAllocationFailed(width: width, height: height) }
        return pool
    }

    /// A homography is not an affine map, so Core Image's perspective filter does it: it is
    /// told where the four corners of the source end up.
    static func perspective(_ image: CIImage, by matrix: simd_float3x3) -> CIImage {
        let extent = image.extent
        func map(_ x: CGFloat, _ y: CGFloat) -> CIVector {
            let p = matrix * SIMD3<Float>(Float(x), Float(y), 1)
            return CIVector(x: CGFloat(p.x / p.z), y: CGFloat(p.y / p.z))
        }
        let filter = CIFilter(name: "CIPerspectiveTransform")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(map(extent.minX, extent.maxY), forKey: "inputTopLeft")
        filter.setValue(map(extent.maxX, extent.maxY), forKey: "inputTopRight")
        filter.setValue(map(extent.maxX, extent.minY), forKey: "inputBottomRight")
        filter.setValue(map(extent.minX, extent.minY), forKey: "inputBottomLeft")
        return filter.outputImage ?? image
    }
}

extension simd_float3x3 {
    /// This matrix as a `CGAffineTransform`, or `nil` if it has a perspective component.
    /// (simd matrices are column-major: `columns.0 = (a, b, _)`, `columns.2 = (tx, ty, 1)`.)
    var affineTransform: CGAffineTransform? {
        guard abs(columns.0.z) < 1e-6, abs(columns.1.z) < 1e-6, abs(columns.2.z - 1) < 1e-6 else { return nil }
        return CGAffineTransform(
            a: CGFloat(columns.0.x), b: CGFloat(columns.0.y),
            c: CGFloat(columns.1.x), d: CGFloat(columns.1.y),
            tx: CGFloat(columns.2.x), ty: CGFloat(columns.2.y)
        )
    }
}
