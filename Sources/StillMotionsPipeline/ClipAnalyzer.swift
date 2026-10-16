import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import simd

/// The analysis half of the pipeline: from a decoded clip to per-frame motion and the
/// signatures loop selection compares. The harness and the app call this same code.
public enum ClipAnalyzer {
    public struct MotionResult {
        public let motion: [FrameMotion]
        /// Native pixel size of the clip.
        public let size: CGSize
        public let frameRate: Double
        /// Frames the estimator rejected or failed on. Each reuses the previous frame's
        /// transform so one bad frame does not sink the clip; the count is reported so it is
        /// not silent. (Failure detection proper is #20.)
        public let estimationFailures: Int
    }

    /// Estimates every frame's motion relative to `referenceIndex`.
    ///
    /// Frames are estimated at `estimationLongEdge` pixels on the long side, not at the preview
    /// size: registration is accurate at 960 px and above but erratic around 600 to 840 px
    /// (decision 0001). Each transform is scaled back into native pixel coordinates.
    public static func estimateMotion(
        movieURL: URL,
        referenceIndex: Int,
        estimator: any MotionEstimator,
        estimationLongEdge: Int = 960,
        renderer: StabilizedRenderer = StabilizedRenderer()
    ) async throws -> MotionResult {
        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.noVideoTrack(movieURL)
        }
        let natural = try await track.load(.naturalSize)
        let frameRate = Double(try await track.load(.nominalFrameRate))
        let size = CGSize(width: natural.width.rounded(), height: natural.height.rounded())
        let scale = min(1, Double(estimationLongEdge) / Double(max(size.width, size.height)))
        let estimationSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let whole = CGRect(origin: .zero, size: size)

        // The reference may be mid-clip, so it has to be found before anything is compared to it.
        var reference: CVPixelBuffer?
        var index = 0
        for frame in try FrameSequence.make(asset: asset, track: track) {
            if index == referenceIndex {
                reference = try renderer.render(frame: frame, correction: matrix_identity_float3x3, crop: whole, outputSize: estimationSize)
                break
            }
            index += 1
        }
        guard let reference else { throw ClipImportError.noVideoTrack(movieURL) }

        let toEstimation = simd_float3x3(diagonal: SIMD3<Float>(Float(scale), Float(scale), 1))
        var motion: [FrameMotion] = []
        var failures = 0
        var previous = matrix_identity_float3x3
        let scratch = try StabilizedRenderer.makeScratchBuffer(width: Int(estimationSize.width), height: Int(estimationSize.height))
        index = 0
        for frame in try FrameSequence.make(asset: asset, track: track) {
            defer { index += 1 }
            if index == referenceIndex {
                motion.append(FrameMotion(index: index, transform: matrix_identity_float3x3))
                continue
            }
            let scaled = try renderer.render(
                frame: frame, correction: matrix_identity_float3x3, crop: whole,
                outputSize: estimationSize, into: scratch
            )
            do {
                let estimated = try await estimator.estimate(frame: scaled, reference: reference)
                // Back into native pixels: T_native = S^-1 * T * S.
                previous = toEstimation.inverse * estimated.transform * toEstimation
                motion.append(FrameMotion(
                    index: index, transform: previous,
                    correspondences: estimated.correspondences, inlierRatio: estimated.inlierRatio
                ))
            } catch {
                failures += 1
                motion.append(FrameMotion(index: index, transform: previous))
            }
        }
        return MotionResult(motion: motion, size: size, frameRate: frameRate, estimationFailures: failures)
    }

    /// One signature per source frame of the STABILIZED, cropped picture, for loop selection.
    public static func signatures(
        movieURL: URL,
        path: CameraPath,
        width: Int = 64,
        renderer: StabilizedRenderer = StabilizedRenderer()
    ) async throws -> [FrameSignature] {
        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.noVideoTrack(movieURL)
        }
        let height = max(2, Int((Double(width) * Double(path.crop.height) / Double(path.crop.width)).rounded()))
        let next = try renderer.makeProducer(
            frames: try FrameSequence.make(asset: asset, track: track),
            corrections: path.corrections, crop: path.crop,
            outputSize: CGSize(width: width, height: height)
        )
        var signatures: [FrameSignature] = []
        while let buffer = try next() {
            // Reading the pixels waits for the GPU render, so the buffer is complete here.
            guard let signature = FrameSignature(pixelBuffer: buffer) else { continue }
            signatures.append(signature)
        }
        return signatures
    }
}
