import Foundation
import simd

/// Ground truth for a synthetic fixture (PRD R-21): the exact transform used to
/// synthesize each frame, so a test can compare a recovered transform against a known
/// answer instead of guessing at real footage.
///
/// Convention, shared with `MotionEstimator` and `CameraPathSolver` (ARCHITECTURE §4):
/// `transform` maps the reference frame's coordinates onto this frame's coordinates, i.e.
/// `pFrame = transform * pReference` in homogeneous coordinates. Stabilizing a frame back
/// onto the reference means applying `transform.inverse`.
public struct FixtureTruth: Codable, Equatable {
    public struct FrameTruth: Codable, Equatable {
        public let index: Int
        /// Row-major 3x3 homogeneous transform: [[a, b, tx], [c, d, ty], [0, 0, 1]].
        public let transform: [[Double]]

        public init(index: Int, transform: [[Double]]) {
            self.index = index
            self.transform = transform
        }

        /// `transform` as a `simd_float3x3`, in the same layout `FrameMotion` uses.
        public var matrix: simd_float3x3 {
            simd_float3x3(rows: [
                SIMD3<Float>(Float(transform[0][0]), Float(transform[0][1]), Float(transform[0][2])),
                SIMD3<Float>(Float(transform[1][0]), Float(transform[1][1]), Float(transform[1][2])),
                SIMD3<Float>(Float(transform[2][0]), Float(transform[2][1]), Float(transform[2][2])),
            ])
        }
    }

    public let name: String
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let frameCount: Int
    /// Index of the frame with identity transform — the synthetic stand-in for the Live
    /// Photo's key-photo timestamp.
    public let referenceFrameIndex: Int
    public let frames: [FrameTruth]

    public init(
        name: String,
        width: Int,
        height: Int,
        frameRate: Double,
        frameCount: Int,
        referenceFrameIndex: Int,
        frames: [FrameTruth]
    ) {
        self.name = name
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.frameCount = frameCount
        self.referenceFrameIndex = referenceFrameIndex
        self.frames = frames
    }

    /// Loads a fixture's sidecar, e.g. `tests/fixtures/synthetic/translate-linear.truth.json`.
    public static func load(from url: URL) throws -> FixtureTruth {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureTruth.self, from: data)
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }
}
