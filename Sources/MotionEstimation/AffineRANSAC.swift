import Foundation
import simd

/// Robust affine fit to matched point pairs: pick three pairs, fit, count how many other pairs
/// agree, keep the best, refit on its inliers. Deterministic (fixed seed), so the same flow
/// field always gives the same transform and tests are repeatable.
///
/// Why RANSAC and not a plain least-squares fit: a moving subject contributes samples that
/// disagree with the camera motion. Least squares averages them in; RANSAC votes them out as
/// long as the background is the majority (decision 0001).
public enum AffineRANSAC {
    public typealias Pair = (from: SIMD2<Double>, to: SIMD2<Double>)

    public struct Fit {
        /// `to = transform * from`, as a 3x3 with bottom row (0, 0, 1).
        public let transform: simd_float3x3
        /// Inliers divided by all pairs given. Measured, not assumed.
        public let inlierRatio: Double
        /// Indices into the input array, in ascending order.
        public let inlierIndices: [Int]
    }

    /// Returns nil when there are fewer than three pairs or no three-pair model gets three
    /// inliers (for example, every pair is collinear).
    public static func fit(_ pairs: [Pair], threshold: Double, iterations: Int = 300, seed: UInt64 = 0x5EED_0011) -> Fit? {
        guard pairs.count >= 3 else { return nil }
        var rng = SplitMix64(seed: seed)
        var bestInliers: [Int] = []
        for _ in 0..<iterations {
            var picks = Set<Int>()
            while picks.count < 3 { picks.insert(Int(rng.next() % UInt64(pairs.count))) }
            guard let model = leastSquares(picks.sorted().map { pairs[$0] }) else { continue }
            var inliers: [Int] = []
            for (i, pair) in pairs.enumerated() where simd_distance(apply(model, to: pair.from), pair.to) <= threshold {
                inliers.append(i)
            }
            if inliers.count > bestInliers.count { bestInliers = inliers }
        }
        guard bestInliers.count >= 3, let refit = leastSquares(bestInliers.map { pairs[$0] }) else { return nil }
        // Refitting on the inliers can move the model enough to change who is an inlier.
        // Re-collect once so the reported ratio describes the transform actually returned.
        var finalInliers: [Int] = []
        for (i, pair) in pairs.enumerated() where simd_distance(apply(refit, to: pair.from), pair.to) <= threshold {
            finalInliers.append(i)
        }
        let transform = simd_float3x3(rows: [
            SIMD3<Float>(Float(refit[0][0]), Float(refit[1][0]), Float(refit[2][0])),
            SIMD3<Float>(Float(refit[0][1]), Float(refit[1][1]), Float(refit[2][1])),
            SIMD3<Float>(0, 0, 1),
        ])
        return Fit(
            transform: transform,
            inlierRatio: Double(finalInliers.count) / Double(pairs.count),
            inlierIndices: finalInliers
        )
    }

    /// Least-squares affine `to = A * from + t`. Nil when the points are degenerate.
    static func leastSquares(_ pairs: [Pair]) -> simd_double3x3? {
        guard pairs.count >= 3 else { return nil }
        var ata = simd_double3x3(0)
        var atx = SIMD3<Double>(0, 0, 0)
        var aty = SIMD3<Double>(0, 0, 0)
        for pair in pairs {
            let row = SIMD3<Double>(pair.from.x, pair.from.y, 1)
            ata += simd_double3x3(columns: (row * row.x, row * row.y, row * row.z))
            atx += row * pair.to.x
            aty += row * pair.to.y
        }
        guard abs(ata.determinant) > 1e-9 else { return nil }
        let inverse = ata.inverse
        // Rows [a b tx], [c d ty], [0 0 1] -> simd columns.
        return simd_double3x3(rows: [inverse * atx, inverse * aty, SIMD3<Double>(0, 0, 1)])
    }

    static func apply(_ matrix: simd_double3x3, to point: SIMD2<Double>) -> SIMD2<Double> {
        let result = matrix * SIMD3<Double>(point.x, point.y, 1)
        return SIMD2<Double>(result.x, result.y)
    }
}

/// Small seeded generator. Not cryptographic; it only has to be repeatable.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
