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

    /// How each frame's motion onto the reference is found.
    public enum Strategy: String, Sendable {
        /// Register every frame directly to the reference frame. Each frame's error is
        /// independent, and frames far from the reference (large displacement, a moved subject,
        /// an exposure change) fall outside what registration can converge on. Fine on the
        /// synthetic clips, erratic on real footage (decision 0008).
        case reference
        /// Register each frame to its neighbour, a small and reliable step, and compose the steps
        /// back to the reference. Errors are small and correlated frame to frame, so the output
        /// does not jitter; the price is slow drift, which over a 1 to 3 second clip is modest.
        case chained
    }

    /// What one step between neighbouring frames may look like. Far tighter than the whole-clip
    /// bounds in `VisionRegistrationEstimator`: neighbouring frames cannot differ by half in scale.
    public static let stepPlausibility = VisionRegistrationEstimator.PlausibilityBounds(
        maxRotation: 8 * .pi / 180, scaleRange: 0.8...1.25, maxTranslationFraction: 0.25
    )

    /// Estimates every frame's motion relative to `referenceIndex`.
    ///
    /// Frames are estimated at `estimationLongEdge` pixels on the long side, not at the preview
    /// size: registration is accurate at 960 px and above but erratic around 600 to 840 px
    /// (decision 0001). Each transform is scaled back into native pixel coordinates.
    ///
    /// Memory: the `.chained` strategy holds the (scaled) frames from the start of the clip up to
    /// the reference, because frames before the reference are chained backwards and decoding only
    /// runs forward. That is about 3 MB a frame at 960 px, and the reference is usually mid-clip.
    public static func estimateMotion(
        movieURL: URL,
        referenceIndex: Int,
        estimator: any MotionEstimator,
        strategy: Strategy = .chained,
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
        let toEstimation = simd_float3x3(diagonal: SIMD3<Float>(Float(scale), Float(scale), 1))

        /// A scaled copy that is the caller's to keep (the renderer's own buffers are reused).
        func scaledCopy(_ frame: CVPixelBuffer, into destination: CVPixelBuffer? = nil) throws -> CVPixelBuffer {
            try renderer.render(frame: frame, correction: matrix_identity_float3x3, crop: whole, outputSize: estimationSize, into: destination)
        }

        var motion: [Int: FrameMotion] = [:]
        var failures = 0
        var count = 0

        switch strategy {
        case .reference:
            var reference: CVPixelBuffer?
            var index = 0
            for frame in try FrameSequence.make(asset: asset, track: track) {
                if index == referenceIndex { reference = try scaledCopy(frame); break }
                index += 1
            }
            guard let reference else { throw ClipImportError.noVideoTrack(movieURL) }

            var previous = matrix_identity_float3x3
            let scratch = try StabilizedRenderer.makeScratchBuffer(width: Int(estimationSize.width), height: Int(estimationSize.height))
            index = 0
            for frame in try FrameSequence.make(asset: asset, track: track) {
                defer { index += 1 }
                if index == referenceIndex {
                    motion[index] = FrameMotion(index: index, transform: matrix_identity_float3x3)
                    continue
                }
                do {
                    let estimated = try await estimator.estimate(frame: try scaledCopy(frame, into: scratch), reference: reference)
                    // Back into native pixels: T_native = S^-1 * T * S.
                    previous = toEstimation.inverse * estimated.transform * toEstimation
                    motion[index] = FrameMotion(index: index, transform: previous, correspondences: estimated.correspondences, inlierRatio: estimated.inlierRatio)
                } catch {
                    failures += 1
                    motion[index] = FrameMotion(index: index, transform: previous)
                }
            }
            count = index

        case .chained:
            // Frames up to and including the reference are kept (scaled); the rest stream past.
            var head: [CVPixelBuffer] = []
            var index = 0
            var previousBuffer: CVPixelBuffer?
            var chain = matrix_identity_float3x3 // T for the previous frame, in estimation coordinates
            let scratch = [
                try StabilizedRenderer.makeScratchBuffer(width: Int(estimationSize.width), height: Int(estimationSize.height)),
                try StabilizedRenderer.makeScratchBuffer(width: Int(estimationSize.width), height: Int(estimationSize.height)),
            ]

            /// One step: where `frame` is, relative to `neighbour`. Identity when it cannot tell.
            func step(frame: CVPixelBuffer, neighbour: CVPixelBuffer) async -> simd_float3x3 {
                do {
                    let estimated = try await estimator.estimate(frame: frame, reference: neighbour)
                    try VisionRegistrationEstimator.checkPlausibility(
                        estimated.transform, frameWidth: Int(estimationSize.width), frameHeight: Int(estimationSize.height),
                        bounds: stepPlausibility
                    )
                    return estimated.transform
                } catch {
                    failures += 1
                    return matrix_identity_float3x3
                }
            }

            for frame in try FrameSequence.make(asset: asset, track: track) {
                defer { index += 1 }
                if index <= referenceIndex {
                    head.append(try scaledCopy(frame))
                    if index == referenceIndex {
                        motion[index] = FrameMotion(index: index, transform: matrix_identity_float3x3)
                        previousBuffer = head[index]
                    }
                    continue
                }
                // Forward from the reference: T_i = step_i * T_(i-1), a step mapping frame i-1 onto frame i.
                let current = try scaledCopy(frame, into: scratch[index % 2])
                guard let neighbour = previousBuffer else { continue }
                chain = await step(frame: current, neighbour: neighbour) * chain
                motion[index] = FrameMotion(index: index, transform: toEstimation.inverse * chain * toEstimation)
                // The next step needs this frame as its neighbour, and the scratch buffers alternate.
                previousBuffer = current
            }
            count = index
            guard head.count > referenceIndex else { throw ClipImportError.noVideoTrack(movieURL) }

            // Backward from the reference, through the frames before it.
            chain = matrix_identity_float3x3
            var i = referenceIndex - 1
            while i >= 0 {
                chain = await step(frame: head[i], neighbour: head[i + 1]) * chain
                motion[i] = FrameMotion(index: i, transform: toEstimation.inverse * chain * toEstimation)
                i -= 1
            }
        }

        let ordered = (0..<count).map { motion[$0] ?? FrameMotion(index: $0, transform: matrix_identity_float3x3) }
        return MotionResult(motion: ordered, size: size, frameRate: frameRate, estimationFailures: failures)
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
