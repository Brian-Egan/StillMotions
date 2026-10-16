import Foundation
import simd

/// A convex polygon with counter-clockwise vertices, in Double. Just enough geometry to
/// intersect warped frame outlines and inscribe a rectangle (see `WarpToReferenceSolver`).
struct ConvexPolygon {
    /// Counter-clockwise. May be degenerate (a segment or a point) near an optimum.
    var vertices: [SIMD2<Double>]

    static let tolerance = 1e-9

    /// Reorders so the vertices run counter-clockwise, whatever orientation they came in.
    init(vertices: [SIMD2<Double>]) {
        self.vertices = Self.signedArea(vertices) < 0 ? vertices.reversed() : vertices
    }

    static func signedArea(_ v: [SIMD2<Double>]) -> Double {
        guard v.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<v.count {
            let a = v[i], b = v[(i + 1) % v.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    var area: Double { Self.signedArea(vertices) }

    /// The outward unit normal and the line offset of every edge: a point `x` is inside the
    /// polygon when `normal . x <= offset` for all edges.
    var edges: [(normal: SIMD2<Double>, offset: Double)] {
        guard vertices.count >= 3 else { return [] }
        return (0..<vertices.count).compactMap { i in
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            let d = b - a
            let length = simd_length(d)
            guard length > Self.tolerance else { return nil }
            // Counter-clockwise, so the outside is to the right of the direction of travel.
            let normal = SIMD2<Double>(d.y, -d.x) / length
            return (normal, simd_dot(normal, a))
        }
    }

    /// Keeps the part where `normal . x <= offset` (Sutherland-Hodgman against one
    /// half-plane). `nil` when nothing is left.
    func clipped(normal: SIMD2<Double>, offset: Double) -> ConvexPolygon? {
        guard !vertices.isEmpty else { return nil }
        var output: [SIMD2<Double>] = []
        for i in 0..<vertices.count {
            let current = vertices[i]
            let previous = vertices[(i + vertices.count - 1) % vertices.count]
            let currentSide = simd_dot(normal, current) - offset
            let previousSide = simd_dot(normal, previous) - offset
            let currentInside = currentSide <= Self.tolerance
            let previousInside = previousSide <= Self.tolerance
            if currentInside != previousInside {
                let t = previousSide / (previousSide - currentSide)
                output.append(previous + (current - previous) * t)
            }
            if currentInside { output.append(current) }
        }
        guard !output.isEmpty else { return nil }
        return ConvexPolygon(vertices: output)
    }

    /// The overlap of two convex polygons: clip `self` by every edge of `other`.
    func intersection(with other: ConvexPolygon) -> ConvexPolygon? {
        var result: ConvexPolygon? = self
        for edge in other.edges {
            guard let current = result else { return nil }
            result = current.clipped(normal: edge.normal, offset: edge.offset)
        }
        guard let result, result.area > Self.tolerance else { return nil }
        return result
    }

    /// The point of this polygon (boundary or interior) nearest to `point`.
    func closestPoint(to point: SIMD2<Double>) -> SIMD2<Double> {
        guard vertices.count > 1 else { return vertices.first ?? point }
        if vertices.count >= 3, area > Self.tolerance,
           edges.allSatisfy({ simd_dot($0.normal, point) <= $0.offset + Self.tolerance })
        {
            return point
        }
        var best = vertices[0]
        var bestDistance = Double.infinity
        for i in 0..<vertices.count {
            let a = vertices[i], b = vertices[(i + 1) % vertices.count]
            let ab = b - a
            let lengthSquared = simd_dot(ab, ab)
            let t = lengthSquared > 0 ? min(max(simd_dot(point - a, ab) / lengthSquared, 0), 1) : 0
            let candidate = a + ab * t
            let distance = simd_distance(candidate, point)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }
}
