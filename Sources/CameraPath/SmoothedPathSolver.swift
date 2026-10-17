import CoreGraphics
import Foundation
import PipelineCore
import simd

/// The "Smooth" stabilization mode: each frame is moved toward a low-passed copy of the path the
/// camera actually took, so the shake goes and the slow drift stays. The crop is whatever is valid in
/// every corrected frame (`CommonCrop`), which is larger than Locked's because the frames move less far
/// from where they were shot.
///
/// For each frame the estimator gives T, mapping reference coordinates onto that frame (see
/// `FrameMotion`). Each T is reduced to a SIMILARITY about the frame center (translation, rotation, and
/// log scale), those four numbers are Gaussian-smoothed over time, and the frame is moved by the
/// difference between its smoothed pose and its own:
///
///     correction = pose(smoothed) * pose(T)^-1
///
/// Locked is a still camera (the target pose is the reference's) and Off is the camera as shot (the
/// target pose is T), so this sits between them.
///
/// Two choices came from running it on 117 real clips (decision 0011):
///
/// 1. **Only the similarity is corrected.** A first version corrected with the full `T^-1`, so any shear or
///    perspective the estimator found was applied too. Where those estimates are noise (the early frames of
///    some chained estimates have scale 0.3 and heavy shear) the smoothed similarity no longer matched the
///    frame, and the common crop collapsed on clips Locked handled at 85%.
/// 2. **Each frame's move is capped.** The smoothed pose may differ from the frame's own by at most a
///    fraction of the frame in translation, a few degrees of rotation, and a few percent of scale. A frame
///    whose estimate is garbage is then left close to as shot instead of being dragged far, which also
///    gives Smooth a floor on how much of the frame it can cost.
///
/// This is deliberately not the L1-optimal solver of decision 0002 / issue #21: a Gaussian over the path is
/// a few dozen lines, has a few numbers to tune, and needs no optimizer.
public struct SmoothedPathSolver: CameraPathSolver {
    /// Standard deviation of the Gaussian, in frames. A clip at about 29 fps with sigma 8 keeps
    /// motion slower than roughly half a hertz and removes what is faster.
    public var sigmaFrames: Double
    /// The most a frame may be moved sideways or up and down, as a fraction of the frame's width and height.
    public var maxShiftFraction: Double
    /// The most a frame may be rotated, in radians.
    public var maxRotation: Double
    /// The most a frame may be scaled, as a natural log (0.05 is about 5%).
    public var maxLogScale: Double

    public static let defaultSigmaFrames = 8.0
    public static let defaultMaxShiftFraction = 0.05
    public static let defaultMaxRotation = 0.03
    public static let defaultMaxLogScale = 0.05

    public init(
        sigmaFrames: Double = SmoothedPathSolver.defaultSigmaFrames,
        maxShiftFraction: Double = SmoothedPathSolver.defaultMaxShiftFraction,
        maxRotation: Double = SmoothedPathSolver.defaultMaxRotation,
        maxLogScale: Double = SmoothedPathSolver.defaultMaxLogScale
    ) {
        self.sigmaFrames = sigmaFrames
        self.maxShiftFraction = maxShiftFraction
        self.maxRotation = maxRotation
        self.maxLogScale = maxLogScale
    }

    public func solve(motion: [FrameMotion], frameSize: CGSize) throws -> CameraPath {
        guard !motion.isEmpty else { throw CameraPathError.noMotion }
        guard frameSize.width > 0, frameSize.height > 0 else { throw CameraPathError.invalidFrameSize(frameSize) }

        let center = SIMD2<Double>(Double(frameSize.width) / 2, Double(frameSize.height) / 2)
        var poses: [Pose] = []
        for frame in motion {
            let determinant = frame.transform.determinant
            guard determinant.isFinite, abs(determinant) > 1e-9 else {
                throw CameraPathError.singularTransform(frameIndex: frame.index)
            }
            poses.append(Pose(frame.transform, aboutCenter: center))
        }

        let smoothed = Self.smooth(poses, sigma: sigmaFrames)
        let maxShift = SIMD2(maxShiftFraction * Double(frameSize.width), maxShiftFraction * Double(frameSize.height))
        let corrections = zip(smoothed, poses).map { target, own in
            // The move that takes the frame from its own pose to the smoothed one, as a similarity
            // about the center, then limited: by how far the CENTER moves, how much the frame turns,
            // and how much it is scaled. These are limits on the actual move, not on the difference
            // between two poses (which interact when a pose is large).
            let move = Pose(target.matrix(aboutCenter: center) * own.matrix(aboutCenter: center).inverse, aboutCenter: center)
            return move.clamped(maxShift: maxShift, maxRotation: maxRotation, maxLogScale: maxLogScale).matrix(aboutCenter: center)
        }
        let crop = try CommonCrop.largest(corrections: corrections, frameIndices: motion.map(\.index), frameSize: frameSize)
        let scale = Double(crop.width) / Double(frameSize.width)
        return CameraPath(corrections: corrections, crop: crop, cropRetention: scale * scale)
    }

    /// A camera pose reduced to a similarity about the frame center.
    struct Pose {
        var tx: Double
        var ty: Double
        var rotation: Double
        var logScale: Double

        init(tx: Double, ty: Double, rotation: Double, logScale: Double) {
            self.tx = tx; self.ty = ty; self.rotation = rotation; self.logScale = logScale
        }

        /// Reads the pose out of `transform`, with coordinates taken relative to `center`.
        init(_ transform: simd_float3x3, aboutCenter center: SIMD2<Double>) {
            // entry(row, column); simd matrices are column-major: m[column][row].
            func entry(_ row: Int, _ column: Int) -> Double { Double(transform[column][row]) }
            let w = entry(2, 2) == 0 ? 1 : entry(2, 2)
            let a = entry(0, 0) / w, b = entry(0, 1) / w, c = entry(1, 0) / w, d = entry(1, 1) / w
            let tx = entry(0, 2) / w, ty = entry(1, 2) / w
            // Center-relative translation: the image of the center point, minus the center.
            let moved = SIMD2<Double>(a * center.x + b * center.y + tx, c * center.x + d * center.y + ty)
            self.tx = moved.x - center.x
            self.ty = moved.y - center.y
            let determinant = a * d - b * c
            logScale = 0.5 * log(max(abs(determinant), 1e-12))
            // Rotation of the first column; for a similarity this is the rotation exactly.
            rotation = atan2(c, a)
        }

        /// Each of the four numbers held within its limit (symmetric about zero). Used on a MOVE, so
        /// this bounds how far the center goes, how much the frame turns and how much it is scaled.
        func clamped(maxShift: SIMD2<Double>, maxRotation: Double, maxLogScale: Double) -> Pose {
            func limited(_ value: Double, _ limit: Double) -> Double { min(max(value, -limit), limit) }
            return Pose(
                tx: limited(tx, maxShift.x), ty: limited(ty, maxShift.y),
                rotation: limited(rotation, maxRotation), logScale: limited(logScale, maxLogScale)
            )
        }

        /// The pose as a matrix in image coordinates, rotating and scaling about `center`.
        func matrix(aboutCenter center: SIMD2<Double>) -> simd_float3x3 {
            let s = exp(logScale), cosine = cos(rotation) * s, sine = sin(rotation) * s
            // Linear part [[cosine, -sine], [sine, cosine]] about the center, then moved by (tx, ty).
            let offsetX = center.x - (cosine * center.x - sine * center.y) + tx
            let offsetY = center.y - (sine * center.x + cosine * center.y) + ty
            return simd_float3x3(columns: (
                SIMD3<Float>(Float(cosine), Float(sine), 0),
                SIMD3<Float>(Float(-sine), Float(cosine), 0),
                SIMD3<Float>(Float(offsetX), Float(offsetY), 1)
            ))
        }
    }

    /// Gaussian smoothing over frame index. At the ends the kernel is cut off and renormalized, so
    /// the first and last frames are averaged from the frames that exist rather than pulled toward
    /// zero. Rotation is unwrapped first so a path crossing +/-pi does not smooth through zero.
    static func smooth(_ poses: [Pose], sigma: Double) -> [Pose] {
        guard poses.count > 1, sigma > 0 else { return poses }
        var rotations = poses.map(\.rotation)
        for i in 1..<rotations.count {
            while rotations[i] - rotations[i - 1] > .pi { rotations[i] -= 2 * .pi }
            while rotations[i] - rotations[i - 1] < -.pi { rotations[i] += 2 * .pi }
        }
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        let kernel = (-radius...radius).map { exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }

        func filtered(_ values: [Double]) -> [Double] {
            (0..<values.count).map { i in
                var sum = 0.0, weight = 0.0
                for k in -radius...radius {
                    let j = i + k
                    guard j >= 0, j < values.count else { continue }
                    let w = kernel[k + radius]
                    sum += w * values[j]
                    weight += w
                }
                return sum / weight
            }
        }
        let tx = filtered(poses.map(\.tx)), ty = filtered(poses.map(\.ty))
        let rotation = filtered(rotations), logScale = filtered(poses.map(\.logScale))
        return (0..<poses.count).map { Pose(tx: tx[$0], ty: ty[$0], rotation: rotation[$0], logScale: logScale[$0]) }
    }
}
