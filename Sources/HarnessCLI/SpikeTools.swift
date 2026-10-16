import CoreImage
import CoreVideo
import Foundation
import simd

// Measurement helpers for `benchmark-estimators` (#10). Spike-grade by design: they exist to
// answer decision 0001's question, and #11 builds the production flow estimator separately.

struct SpikeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Pixel buffers

enum SpikeBuffers {
    static func makeBGRA(width: Int, height: Int) throws -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &out)
        guard let buffer = out else { throw SpikeError("could not allocate \(width)x\(height) pixel buffer") }
        return buffer
    }

    /// Scales so the long edge becomes `longEdge`. Returns the input unchanged (and scale 1)
    /// when it is already that size, so "native" costs nothing.
    static func scaled(_ buffer: CVPixelBuffer, longEdge: Int, context: CIContext) throws -> (buffer: CVPixelBuffer, scale: Double) {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let currentLong = max(width, height)
        if currentLong == longEdge { return (buffer, 1) }
        let scale = Double(longEdge) / Double(currentLong)
        let newWidth = Int((Double(width) * scale).rounded())
        let newHeight = Int((Double(height) * scale).rounded())
        let out = try makeBGRA(width: newWidth, height: newHeight)
        let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        context.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: newWidth, height: newHeight), colorSpace: nil)
        return (out, scale)
    }

    static func render(_ image: CIImage, width: Int, height: Int, context: CIContext) throws -> CVPixelBuffer {
        let out = try makeBGRA(width: width, height: height)
        context.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return out
    }

    /// A copy with every masked pixel painted mid-grey. This is registration's only masking
    /// lever (decision 0001): there is no hook to exclude a region, so the subject has to be
    /// blanked out of the pixels themselves — which changes the image content.
    static func blanked(_ buffer: CVPixelBuffer, mask: SubjectMask) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let copy = try makeBGRA(width: width, height: height)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(copy, [])
        }
        guard let src = CVPixelBufferGetBaseAddress(buffer), let dst = CVPixelBufferGetBaseAddress(copy) else {
            throw SpikeError("pixel buffer has no base address")
        }
        let srcStride = CVPixelBufferGetBytesPerRow(buffer)
        let dstStride = CVPixelBufferGetBytesPerRow(copy)
        for y in 0..<height {
            let srcRow = src.advanced(by: y * srcStride).assumingMemoryBound(to: UInt8.self)
            let dstRow = dst.advanced(by: y * dstStride).assumingMemoryBound(to: UInt8.self)
            let ny = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let nx = (Double(x) + 0.5) / Double(width)
                let masked = mask.contains(nx: nx, ny: ny)
                for c in 0..<4 {
                    dstRow[x * 4 + c] = masked && c < 3 ? 128 : srcRow[x * 4 + c]
                }
            }
        }
        return copy
    }
}

// MARK: - Subject mask

/// A coarse, already-dilated bitmap of "this pixel belongs to a moving subject", kept at a
/// fixed small resolution so the same mask serves every estimation resolution. Coordinates
/// are normalized with a TOP-left origin, matching image rows.
struct SubjectMask {
    static let gridWidth = 480
    static let gridHeight = 270

    let cells: [UInt8]

    var coverage: Double {
        Double(cells.reduce(0) { $0 + Int($1) }) / Double(cells.count)
    }

    func contains(nx: Double, ny: Double) -> Bool {
        let x = min(max(Int(nx * Double(Self.gridWidth)), 0), Self.gridWidth - 1)
        let y = min(max(Int(ny * Double(Self.gridHeight)), 0), Self.gridHeight - 1)
        return cells[y * Self.gridWidth + x] != 0
    }

    /// `rawCells` is any bitmap on the fixed grid; the result is dilated by `radius` cells
    /// (each cell is 4 native pixels on a 1920-wide frame). Flow is unreliable right at a
    /// moving boundary, so the exclusion zone has to be a little bigger than the subject.
    static func dilated(rawCells: [UInt8], radius: Int) -> SubjectMask {
        let w = gridWidth, h = gridHeight
        var horizontal = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w where rawCells[y * w + x] != 0 {
                for dx in max(0, x - radius)...min(w - 1, x + radius) { horizontal[y * w + dx] = 1 }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w where horizontal[y * w + x] != 0 {
                for dy in max(0, y - radius)...min(h - 1, y + radius) { out[dy * w + x] = 1 }
            }
        }
        return SubjectMask(cells: out)
    }

    /// Reads a single-channel mask buffer (8-bit or 32-bit float, either may come back from
    /// Vision) into the fixed grid by nearest sampling.
    static func fromSingleChannel(_ buffer: CVPixelBuffer, threshold: Float = 0.5, dilationRadius: Int) throws -> SubjectMask {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpikeError("mask has no base address") }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        var raw = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            let y = min(height - 1, Int((Double(gy) + 0.5) / Double(gridHeight) * Double(height)))
            let row = base.advanced(by: y * stride)
            for gx in 0..<gridWidth {
                let x = min(width - 1, Int((Double(gx) + 0.5) / Double(gridWidth) * Double(width)))
                let on: Bool
                switch format {
                case kCVPixelFormatType_OneComponent8:
                    on = Float(row.load(fromByteOffset: x, as: UInt8.self)) / 255 >= threshold
                case kCVPixelFormatType_OneComponent32Float:
                    on = row.load(fromByteOffset: x * 4, as: Float.self) >= threshold
                case kCVPixelFormatType_OneComponent16Half:
                    on = Float(row.load(fromByteOffset: x * 2, as: Float16.self)) >= threshold
                default:
                    throw SpikeError("unsupported mask pixel format \(format)")
                }
                raw[gy * gridWidth + gx] = on ? 1 : 0
            }
        }
        return dilated(rawCells: raw, radius: dilationRadius)
    }

    /// From an RGBA render where the subject is bright on black.
    static func fromBrightness(_ buffer: CVPixelBuffer, dilationRadius: Int) throws -> SubjectMask {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SpikeError("mask has no base address") }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var raw = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            let y = min(height - 1, Int((Double(gy) + 0.5) / Double(gridHeight) * Double(height)))
            let row = base.advanced(by: y * stride)
            for gx in 0..<gridWidth {
                let x = min(width - 1, Int((Double(gx) + 0.5) / Double(gridWidth) * Double(width)))
                raw[gy * gridWidth + gx] = row.load(fromByteOffset: x * 4 + 1, as: UInt8.self) > 128 ? 1 : 0
            }
        }
        return dilated(rawCells: raw, radius: dilationRadius)
    }
}

// MARK: - Memory

/// Polls this process's `phys_footprint` (the figure jetsam uses) on a background thread
/// and reports the peak above the level when sampling started. Macs have far more memory
/// than the iPhone 14 Pro, so this is a relative signal, not a budget check.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = false
    private var baseline: UInt64 = 0

    static func currentFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    func start() {
        lock.lock()
        baseline = Self.currentFootprint()
        peak = baseline
        running = true
        lock.unlock()
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let stillRunning = running
                if stillRunning { peak = max(peak, Self.currentFootprint()) }
                lock.unlock()
                if !stillRunning { break }
                usleep(2000)
            }
        }
        thread.start()
    }

    /// Peak growth over the starting footprint, in megabytes.
    func stop() -> Double {
        lock.lock()
        peak = max(peak, Self.currentFootprint())
        running = false
        let growth = peak > baseline ? peak - baseline : 0
        lock.unlock()
        return Double(growth) / 1_048_576
    }
}

// MARK: - Accuracy

enum SpikeAccuracy {
    /// RMS displacement in native pixels between `recovered` and `truth` over a 5x5 grid.
    /// Same measure as `MotionEstimationTests.rms`, so numbers compare with #9's table.
    static func rms(recovered: simd_float3x3, truth: simd_float3x3, frameSize: CGSize) -> Double {
        var sumSquared = 0.0
        var count = 0
        for gx in stride(from: 0.1, through: 0.9, by: 0.2) {
            for gy in stride(from: 0.1, through: 0.9, by: 0.2) {
                let p = SIMD3<Float>(Float(gx * frameSize.width), Float(gy * frameSize.height), 1)
                let pr = recovered * p
                let pt = truth * p
                let dx = Double(pr.x / pr.z - pt.x / pt.z)
                let dy = Double(pr.y / pr.z - pt.y / pt.z)
                sumSquared += dx * dx + dy * dy
                count += 1
            }
        }
        return (sumSquared / Double(count)).squareRoot()
    }

    /// A transform estimated on a frame scaled by `scale`, expressed back in native pixels.
    static func toNative(_ transform: simd_float3x3, scale: Double) -> simd_float3x3 {
        let s = Float(scale)
        let down = simd_float3x3(diagonal: SIMD3<Float>(s, s, 1))
        return down.inverse * transform * down
    }
}

// MARK: - Affine fit with RANSAC

struct SpikeFit {
    let transform: simd_float3x3
    let inlierRatio: Double
    let inliers: Int
    let inlierIndices: [Int]
}

enum SpikeAffine {
    typealias Pair = (from: SIMD2<Double>, to: SIMD2<Double>)

    /// Least-squares affine `to = A * from + t`.
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
        let px = inverse * atx
        let py = inverse * aty
        // Rows [a b tx], [c d ty], [0 0 1] -> simd columns.
        return simd_double3x3(rows: [px, py, SIMD3<Double>(0, 0, 1)])
    }

    static func apply(_ m: simd_double3x3, to p: SIMD2<Double>) -> SIMD2<Double> {
        let r = m * SIMD3<Double>(p.x, p.y, 1)
        return SIMD2<Double>(r.x, r.y)
    }

    /// Deterministic RANSAC: fixed seed, so the same flow field always yields the same fit.
    static func ransac(_ pairs: [Pair], threshold: Double, iterations: Int = 300) -> SpikeFit? {
        guard pairs.count >= 3 else { return nil }
        var rng = DeterministicRNG(seed: 0x5EED_0010)
        var best: (inliers: [Int], model: simd_double3x3)?
        for _ in 0..<iterations {
            var picks = Set<Int>()
            while picks.count < 3 { picks.insert(Int(rng.nextUnit() * Double(pairs.count)) % pairs.count) }
            guard let model = leastSquares(picks.map { pairs[$0] }) else { continue }
            var inliers: [Int] = []
            for (i, pair) in pairs.enumerated() where simd_distance(apply(model, to: pair.from), pair.to) <= threshold {
                inliers.append(i)
            }
            if inliers.count > (best?.inliers.count ?? 0) { best = (inliers, model) }
        }
        guard let best, best.inliers.count >= 3, let refit = leastSquares(best.inliers.map { pairs[$0] }) else { return nil }
        let t = simd_float3x3(rows: [
            SIMD3<Float>(Float(refit[0][0]), Float(refit[1][0]), Float(refit[2][0])),
            SIMD3<Float>(Float(refit[0][1]), Float(refit[1][1]), Float(refit[2][1])),
            SIMD3<Float>(0, 0, 1),
        ])
        return SpikeFit(transform: t, inlierRatio: Double(best.inliers.count) / Double(pairs.count), inliers: best.inliers.count, inlierIndices: best.inliers)
    }
}
