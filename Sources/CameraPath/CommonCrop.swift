import CoreGraphics
import Foundation
import PipelineCore
import simd

/// The largest crop that is valid in every frame once each is warped by its correction.
///
/// Warping a frame turns its rectangle into a quadrilateral; the area valid in *all* frames is the
/// intersection of those quadrilaterals, which is a convex polygon. A rectangle of fixed aspect
/// ratio fits inside a convex polygon exactly when its four corners do, so with center `c`, scale
/// `s` (crop is `s` times the frame size) and each polygon edge written as `n . x <= d` (outward
/// unit normal `n`), the condition is one linear inequality per edge:
///
///     n . c + s * (|n.x| * W + |n.y| * H) / 2 <= d
///
/// Maximizing `s` is then a three-variable linear program. Rather than ship a general LP solver
/// this bisects on `s` and clips the set of allowed centers, which is exact to floating-point
/// precision and a few dozen lines. Shrinking uniformly from the largest displacement would be
/// simpler but gives up crop, and crop retention is the number the L1 gate turns on (0002).
///
/// Shared by every stabilization mode: they differ only in the corrections they produce.
enum CommonCrop {
    /// `frameIndices[i]` names the frame `corrections[i]` belongs to, for error messages.
    static func largest(corrections: [simd_float3x3], frameIndices: [Int], frameSize: CGSize) throws -> CGRect {
        let width = Double(frameSize.width)
        let height = Double(frameSize.height)

        // The reference frame's own rectangle always bounds the output.
        var valid = ConvexPolygon(vertices: [
            SIMD2(0, 0), SIMD2(width, 0), SIMD2(width, height), SIMD2(0, height),
        ])
        for (correction, index) in zip(corrections, frameIndices) {
            // Where this frame's rectangle lands in output coordinates once stabilized.
            let corners: [SIMD2<Double>] = [
                SIMD2(0, 0), SIMD2(width, 0), SIMD2(width, height), SIMD2(0, height),
            ]
            var warped: [SIMD2<Double>] = []
            for corner in corners {
                let p = correction * SIMD3<Float>(Float(corner.x), Float(corner.y), 1)
                guard p.z > 1e-6 else { throw CameraPathError.noCommonRegion(frameIndex: index) }
                warped.append(SIMD2(Double(p.x / p.z), Double(p.y / p.z)))
            }
            guard let overlap = valid.intersection(with: ConvexPolygon(vertices: warped)) else {
                throw CameraPathError.noCommonRegion(frameIndex: index)
            }
            valid = overlap
        }

        let lastFrameIndex = frameIndices.last ?? 0
        let edges = valid.edges
        // Half the crop's extent, along each edge's normal, per unit of scale.
        let reach = edges.map { (abs($0.normal.x) * width + abs($0.normal.y) * height) / 2 }

        // The set of centers that keep a crop of scale `s` inside `valid`.
        func allowedCenters(scale s: Double) -> ConvexPolygon? {
            var region: ConvexPolygon? = ConvexPolygon(vertices: [
                SIMD2(-1, -1), SIMD2(width + 1, -1), SIMD2(width + 1, height + 1), SIMD2(-1, height + 1),
            ])
            for (edge, r) in zip(edges, reach) {
                guard let current = region else { return nil }
                region = current.clipped(normal: edge.normal, offset: edge.offset - s * r)
            }
            return region
        }

        // A crop at scale `s` exists iff some center is allowed. Feasibility is monotone in
        // `s`, so bisect for the largest one.
        guard allowedCenters(scale: 1e-3) != nil else {
            throw CameraPathError.noCommonRegion(frameIndex: lastFrameIndex)
        }
        var low = 1e-3, high = 1.0
        if allowedCenters(scale: high) != nil {
            low = high
        } else {
            for _ in 0..<60 {
                let mid = (low + high) / 2
                if allowedCenters(scale: mid) != nil { low = mid } else { high = mid }
            }
        }

        // Back off a hair so the allowed centers are a sliver, not a single point, then take
        // the one closest to the frame center: when the crop is limited in one direction only,
        // this keeps it centered in the other.
        let scale = low * (1 - 1e-9)
        guard let centers = allowedCenters(scale: scale) else {
            throw CameraPathError.noCommonRegion(frameIndex: lastFrameIndex)
        }
        let center = centers.closestPoint(to: SIMD2(width / 2, height / 2))
        let crop = CGRect(
            x: center.x - scale * width / 2,
            y: center.y - scale * height / 2,
            width: scale * width,
            height: scale * height
        )
        return crop
    }
}
