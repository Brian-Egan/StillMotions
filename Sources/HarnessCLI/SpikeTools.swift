import CoreImage
import CoreVideo
import Foundation
import StillMotionsPipeline
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

    /// See `SubjectMask.blanking`.
    static func blanked(_ buffer: CVPixelBuffer, mask: SubjectMask) throws -> CVPixelBuffer {
        try mask.blanking(buffer)
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
