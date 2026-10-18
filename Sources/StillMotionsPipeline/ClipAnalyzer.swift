import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import simd

/// The analysis half of the pipeline: from a decoded clip to per-frame motion and the
/// signatures loop selection compares. The harness and the app call this same code.
public enum ClipAnalyzer {
    public struct MotionResult: Sendable {
        public let motion: [FrameMotion]
        /// Native pixel size of the clip.
        public let size: CGSize
        public let frameRate: Double
        /// Each frame's presentation time in seconds. Real Live Photo video is variable frame rate.
        public let frameTimes: [Double]
        /// Frames the estimator rejected or failed on. Each reuses the previous frame's
        /// transform so one bad frame does not sink the clip; the count is reported so it is
        /// not silent. (Failure detection proper is #20.)
        public let estimationFailures: Int
        /// Frames whose subject mask was applied (masking on, and something was found).
        public let maskedFrames: Int
        /// Frames whose mask covered too much of the picture and was discarded (PRD R-6).
        public let maskSkippedFrames: Int
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
        /// When given, moving subjects (people, pets, other foreground) are masked out of the
        /// estimate. Nil leaves masking off, which is what every caller got before #19.
        masker: SubjectMasker? = nil,
        renderer: StabilizedRenderer = StabilizedRenderer()
    ) async throws -> MotionResult {
        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.noVideoTrack(movieURL)
        }
        let natural = try await TrackOrientation.load(from: track).uprightSize(try await track.load(.naturalSize))
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
        var maskedFrames = 0
        var maskSkippedFrames = 0

        /// The subject mask for an (already scaled) frame; empty when masking is off or fails.
        func maskOf(_ buffer: CVPixelBuffer) async -> SubjectMask {
            guard let masker, let result = try? await masker.mask(for: buffer) else { return .empty }
            if result.skipped { maskSkippedFrames += 1 } else if !result.mask.isEmpty { maskedFrames += 1 }
            return result.mask
        }

        /// One estimate, with the subjects of BOTH frames kept out of it. Flow drops the samples
        /// inside the masks; registration cannot, so both pictures get the union painted grey.
        func masked(frame: CVPixelBuffer, frameMask: SubjectMask, reference: CVPixelBuffer, referenceMask: SubjectMask) async throws -> FrameMotion {
            if frameMask.isEmpty && referenceMask.isEmpty {
                return try await estimator.estimate(frame: frame, reference: reference)
            }
            if let flow = estimator as? OpticalFlowEstimator {
                return try await flow.estimateWithEvidence(frame: frame, reference: reference, frameMask: frameMask, referenceMask: referenceMask).motion
            }
            let both = frameMask.union(referenceMask)
            return try await estimator.estimate(frame: try both.inpainting(frame), reference: try both.inpainting(reference))
        }

        switch strategy {
        case .reference:
            var reference: CVPixelBuffer?
            var index = 0
            for frame in try FrameSequence.make(asset: asset, track: track) {
                if index == referenceIndex { reference = try scaledCopy(frame); break }
                index += 1
            }
            guard let reference else { throw ClipImportError.noVideoTrack(movieURL) }
            let referenceMask = await maskOf(reference)

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
                    let scaledFrame = try scaledCopy(frame, into: scratch)
                    let estimated = try await masked(frame: scaledFrame, frameMask: await maskOf(scaledFrame), reference: reference, referenceMask: referenceMask)
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
            var headMasks: [SubjectMask] = []
            var previousMask = SubjectMask.empty
            var index = 0
            var previousBuffer: CVPixelBuffer?
            var chain = matrix_identity_float3x3 // T for the previous frame, in estimation coordinates
            let scratch = [
                try StabilizedRenderer.makeScratchBuffer(width: Int(estimationSize.width), height: Int(estimationSize.height)),
                try StabilizedRenderer.makeScratchBuffer(width: Int(estimationSize.width), height: Int(estimationSize.height)),
            ]

            /// One step: where `frame` is, relative to `neighbour`. Identity when it cannot tell.
            func step(frame: CVPixelBuffer, frameMask: SubjectMask, neighbour: CVPixelBuffer, neighbourMask: SubjectMask) async -> simd_float3x3 {
                do {
                    let estimated = try await masked(frame: frame, frameMask: frameMask, reference: neighbour, referenceMask: neighbourMask)
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
                    let copy = try scaledCopy(frame)
                    head.append(copy)
                    headMasks.append(await maskOf(copy))
                    if index == referenceIndex {
                        motion[index] = FrameMotion(index: index, transform: matrix_identity_float3x3)
                        previousBuffer = head[index]
                        previousMask = headMasks[index]
                    }
                    continue
                }
                // Forward from the reference: T_i = step_i * T_(i-1), a step mapping frame i-1 onto frame i.
                let current = try scaledCopy(frame, into: scratch[index % 2])
                guard let neighbour = previousBuffer else { continue }
                let currentMask = await maskOf(current)
                chain = await step(frame: current, frameMask: currentMask, neighbour: neighbour, neighbourMask: previousMask) * chain
                motion[index] = FrameMotion(index: index, transform: toEstimation.inverse * chain * toEstimation)
                // The next step needs this frame as its neighbour, and the scratch buffers alternate.
                previousBuffer = current
                previousMask = currentMask
            }
            count = index
            guard head.count > referenceIndex else { throw ClipImportError.noVideoTrack(movieURL) }

            // Backward from the reference, through the frames before it.
            chain = matrix_identity_float3x3
            var i = referenceIndex - 1
            while i >= 0 {
                chain = await step(frame: head[i], frameMask: headMasks[i], neighbour: head[i + 1], neighbourMask: headMasks[i + 1]) * chain
                motion[i] = FrameMotion(index: i, transform: toEstimation.inverse * chain * toEstimation)
                i -= 1
            }
        }

        let ordered = (0..<count).map { motion[$0] ?? FrameMotion(index: $0, transform: matrix_identity_float3x3) }
        let frameTimes = try FrameSequence.presentationTimes(asset: asset, track: track)
        return MotionResult(motion: ordered, size: size, frameRate: frameRate, frameTimes: frameTimes, estimationFailures: failures, maskedFrames: maskedFrames, maskSkippedFrames: maskSkippedFrames)
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
