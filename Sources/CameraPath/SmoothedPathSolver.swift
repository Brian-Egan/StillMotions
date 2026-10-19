import CoreGraphics
import Foundation
import PipelineCore
import simd

/// The "Smooth" stabilization mode: each frame is moved toward a low-passed copy of the path the
/// camera actually took, so the shake goes and the slow drift stays. The crop is whatever is valid in
/// every corrected frame (`CommonCrop`), which is larger than Locked's because the frames move less
/// far from where they were shot.
///
/// For each frame the estimator gives T, mapping reference coordinates onto that frame (see
/// `FrameMotion`). T is the camera's pose. The virtual camera takes S, a Gaussian-smoothed copy of
/// those poses, and each frame is moved to where that camera would show it:
///
///     correction = S * T^-1
///
/// Locked is S = identity (a still camera) and Off is S = T (the camera as shot), so this sits between
/// them.
///
/// **Smoothing the matrices, not a decomposition of them.** The smoothing is applied to the entries of T
/// directly. That is a linear filter, so where any point of the scene lands is filtered exactly as a
/// plain Gaussian would filter its path, and it cannot add jitter. A first version split each T into
/// shift, rotation and scale and smoothed those separately, and on 117 real clips it made about half
/// of them jitterier than the footage as shot: estimator noise is correlated across those numbers, and
/// smoothing them independently breaks the cancellation (decision 0011).
///
/// **A limit on how far any frame moves.** No corner of any frame is moved by more than
/// `maxMoveFraction` of the frame's diagonal. Where an estimate is garbage (some chained estimates start
/// with scale 0.3 and heavy shear) the smoothed path can be far from the frame, and without a limit the
/// common crop collapses on clips Locked handles at 85%. The limit is soft, `limit * tanh(move / limit)`
/// applied to the whole correction, so it is nearly invisible for ordinary moves and, being continuous,
/// cannot make a hovering path switch on and off from frame to frame (a hard clamp did, and that was
/// itself jitter).
///
/// This is deliberately not the L1-optimal solver of decision 0002 / issue #21: a Gaussian over the path is
/// a few dozen lines, has two numbers to tune, and needs no optimizer.
public struct SmoothedPathSolver: CameraPathSolver {
    /// Standard deviation of the Gaussian, in frames. A clip at about 29 fps with sigma 8 keeps
    /// motion slower than roughly half a hertz and removes what is faster.
    public var sigmaFrames: Double
    /// The most any corner of any frame may be moved, as a fraction of the frame's diagonal.
    public var maxMoveFraction: Double

    public static let defaultSigmaFrames = 8.0
    public static let defaultMaxMoveFraction = 0.06

    public init(
        sigmaFrames: Double = SmoothedPathSolver.defaultSigmaFrames,
        maxMoveFraction: Double = SmoothedPathSolver.defaultMaxMoveFraction
    ) {
        self.sigmaFrames = sigmaFrames
        self.maxMoveFraction = maxMoveFraction
    }

    public func solve(motion: [FrameMotion], frameSize: CGSize) throws -> CameraPath {
        guard !motion.isEmpty else { throw CameraPathError.noMotion }
        guard frameSize.width > 0, frameSize.height > 0 else { throw CameraPathError.invalidFrameSize(frameSize) }

        var poses: [simd_double3x3] = []
        for frame in motion {
            let determinant = frame.transform.determinant
            guard determinant.isFinite, abs(determinant) > 1e-9, frame.transform[2][2] != 0 else {
                throw CameraPathError.singularTransform(frameIndex: frame.index)
            }
            poses.append(Self.normalized(frame.transform))
        }

        let smoothed = Self.smooth(poses, sigma: sigmaFrames)
        let width = Double(frameSize.width), height = Double(frameSize.height)
        let limit = maxMoveFraction * (width * width + height * height).squareRoot()
        let corners: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(width, 0), SIMD2(width, height), SIMD2(0, height)]

        let corrections: [simd_float3x3] = zip(smoothed, poses).map { target, own in
            let move = target * own.inverse
            let limited = Self.limiting(move, corners: corners, limit: limit)
            return simd_float3x3(
                columns: (
                    SIMD3<Float>(Float(limited[0][0]), Float(limited[0][1]), Float(limited[0][2])),
                    SIMD3<Float>(Float(limited[1][0]), Float(limited[1][1]), Float(limited[1][2])),
                    SIMD3<Float>(Float(limited[2][0]), Float(limited[2][1]), Float(limited[2][2]))
                )
            )
        }
        let crop = try CommonCrop.largest(corrections: corrections, frameIndices: motion.map(\.index), frameSize: frameSize)
        let scale = Double(crop.width) / Double(frameSize.width)
        return CameraPath(corrections: corrections, crop: crop, cropRetention: scale * scale)
    }

    /// `transform` as a double-precision matrix scaled so its bottom-right entry is 1.
    static func normalized(_ transform: simd_float3x3) -> simd_double3x3 {
        let w = Double(transform[2][2])
        return simd_double3x3(columns: (
            SIMD3<Double>(Double(transform[0][0]), Double(transform[0][1]), Double(transform[0][2])) / w,
            SIMD3<Double>(Double(transform[1][0]), Double(transform[1][1]), Double(transform[1][2])) / w,
            SIMD3<Double>(Double(transform[2][0]), Double(transform[2][1]), Double(transform[2][2])) / w
        ))
    }

    /// Gaussian smoothing, entry by entry, over frame index.
    ///
    /// **Past the ends the path is extended by reflecting it through the end point** (`2 * end - inside`),
    /// not by cutting the kernel off. Cutting it off averages the first and last frames from one side only,
    /// which drags them toward the middle of the clip: on a path that trends (a zoom, a roll, a pan) the
    /// smoothed value then lags the real one by about `sigma` frames of that trend, and the correction has
    /// to shrink or turn whole frames to make up for it. On a selfie clip whose scale falls from 1.29 to
    /// 0.89 that cost a quarter of the frame (issue #98). A reflection through the end point continues any
    /// straight-line trend exactly, so a steady zoom or pan is left alone right up to the first and last
    /// frame. Where the path is genuinely flat the reflection is flat too, so a constant path stays constant.
    static func smooth(_ matrices: [simd_double3x3], sigma: Double) -> [simd_double3x3] {
        let count = matrices.count
        guard count > 1, sigma > 0 else { return matrices }
        let radius = max(1, Int((3 * sigma).rounded(.up)))
        let kernel = (-radius...radius).map { exp(-0.5 * Double($0 * $0) / (sigma * sigma)) }
        let total = kernel.reduce(0, +)

        /// The path at any index, extended past the ends by point reflection. A reflection that would
        /// itself fall outside a very short clip is held at the nearest frame.
        func extended(_ j: Int) -> simd_double3x3 {
            if j < 0 { return matrices[0] * 2 - matrices[min(count - 1, -j)] }
            if j >= count { return matrices[count - 1] * 2 - matrices[max(0, 2 * (count - 1) - j)] }
            return matrices[j]
        }
        return (0..<count).map { i in
            var sum = simd_double3x3(0)
            for k in -radius...radius { sum += extended(i + k) * kernel[k + radius] }
            return sum * (1 / total)
        }
    }

    /// `move` with its distance from the identity eased so that no corner moves by `limit` or more:
    /// `identity + g * (move - identity)`, with `g` chosen so the largest corner move `m` becomes
    /// `limit * tanh(m / limit)`. For `m` well under `limit`, `g` is almost 1.
    static func limiting(_ move: simd_double3x3, corners: [SIMD2<Double>], limit: Double) -> simd_double3x3 {
        guard limit > 0 else { return matrix_identity_double3x3 }
        var largest = 0.0
        for corner in corners {
            let p = move * SIMD3<Double>(corner.x, corner.y, 1)
            guard abs(p.z) > 1e-9 else { return matrix_identity_double3x3 }
            largest = max(largest, simd_distance(SIMD2(p.x / p.z, p.y / p.z), corner))
        }
        guard largest > 1e-12 else { return move }
        let g = limit * tanh(largest / limit) / largest
        return matrix_identity_double3x3 + (move - matrix_identity_double3x3) * g
    }
}
