import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import simd

/// How much a clip's picture moves, measured from its FRAMES by phase correlation (FFT) at a small
/// fixed size (issue #98).
///
/// This deliberately uses a different method from the stabilizer. The stabilizer minimizes its own
/// estimator's error, so measuring its output with the same estimator would hide exactly the errors
/// that matter. Phase correlation looks only at the pictures, so it works the same on our renders, on
/// the original clip and on another app's GIF, which is what makes them comparable.
enum OutputMotion {
    /// Every picture is shrunk to a SQUARE of this size, stretching it, so the FFT needs no zero
    /// padding (padding adds a hard edge that pulls every shift toward zero). A stretch changes the
    /// scale of x and y shifts, so they are converted back to the 180x240 pixels the reference
    /// script reports (`unitsX`, `unitsY`).
    static let width = 256, height = 256
    static let fft = 256
    static let unitsX = 180.0 / 256, unitsY = 240.0 / 256
    /// Window, in SECONDS, for the moving average that defines "shake": slow camera movement lives in
    /// it, fast jitter is what is left over. A window of frames would be a different length of time at
    /// 20 and 33 frames per second, and the pictures could not be compared (issue #98).
    static let averageWindowSeconds = 0.3

    struct Result: Codable {
        let frames: Int
        /// RMS distance of the camera path from its own 0.3 s moving average, in pixels at 180x240:
        /// the fast shake the eye sees. Slow panning does not count.
        let jitter: Double
        let xRange: Double
        let yRange: Double
        /// Distance between where the path starts and where it ends: how much pan is left in.
        let netPan: Double
        let stepMax: Double
        /// Index of the frame whose step from the one before is largest.
        let stepMaxFrame: Int
        /// Steps bigger than 3 px, as (frame, size): the visible jumps.
        let bigSteps: [[Double]]
    }

    // MARK: - Measuring

    /// `frames` are gray images of `width` x `height`, row-major, and `times` the seconds at which each
    /// is shown (so a clip's own timing, or a GIF's delays, decides what 0.3 s means).
    static func measure(frames: [[Float]], times: [Double]) -> Result {
        summarize(cameraPath(frames: frames), times: times)
    }

    static func summarize(_ path: [SIMD2<Double>], times: [Double]) -> Result {
        let n = path.count
        let t = times.count == n ? times : (0..<n).map { Double($0) / 30 }

        /// The path at time `at`: straight lines between frames, and past either end the path reflected
        /// through the end point, which continues a steady trend (the same idea as the solver's).
        func position(_ at: Double) -> SIMD2<Double> {
            guard n > 1 else { return path.first ?? .zero }
            if at < t[0] { return 2 * path[0] - position(2 * t[0] - at) }
            if at > t[n - 1] { return 2 * path[n - 1] - position(2 * t[n - 1] - at) }
            var j = 0
            while j < n - 2, t[j + 1] < at { j += 1 }
            let span = t[j + 1] - t[j]
            let f = span > 0 ? (at - t[j]) / span : 0
            return path[j] + (path[j + 1] - path[j]) * f
        }

        let samples = 9
        var squared = 0.0
        for i in 0..<n {
            var sum = SIMD2<Double>(0, 0)
            for s in 0..<samples {
                let offset = (Double(s) / Double(samples - 1) - 0.5) * averageWindowSeconds
                sum += position(t[i] + offset)
            }
            let delta = path[i] - sum / Double(samples)
            squared += delta.x * delta.x + delta.y * delta.y
        }
        let steps = (1..<max(1, n)).map { (frame: $0, size: simd_length(path[$0] - path[$0 - 1])) }
        let biggest = steps.max { $0.size < $1.size }
        let xs = path.map(\.x), ys = path.map(\.y)
        return Result(
            frames: n, jitter: n > 0 ? (squared / Double(n)).squareRoot() : 0,
            xRange: (xs.max() ?? 0) - (xs.min() ?? 0), yRange: (ys.max() ?? 0) - (ys.min() ?? 0),
            netPan: n > 1 ? simd_length(path[n - 1] - path[0]) : 0,
            stepMax: biggest?.size ?? 0, stepMaxFrame: biggest?.frame ?? 0,
            bigSteps: steps.filter { $0.size > 3 }.map { [Double($0.frame), $0.size] }
        )
    }

    /// The camera's path: where each frame's picture sits relative to the first, accumulated from the
    /// shift between each pair of consecutive frames.
    static func cameraPath(frames: [[Float]]) -> [SIMD2<Double>] {
        guard !frames.isEmpty else { return [] }
        let correlator = PhaseCorrelator()
        var spectra = frames.map { correlator.spectrum(of: $0) }
        var path = [SIMD2<Double>(0, 0)]
        for i in 1..<max(1, frames.count) {
            let shift = correlator.shift(of: spectra[i], relativeTo: spectra[i - 1])
            path.append(path[i - 1] + SIMD2(shift.x * unitsX, shift.y * unitsY))
            spectra[i - 1] = ([], [])   // not needed again; keeps memory small
        }
        return path
    }

    // MARK: - Frames to gray

    /// A rendered BGRA buffer as gray, row-major. The buffer must already be `width` x `height`.
    static func gray(of buffer: CVPixelBuffer) -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let p = base + y * stride + x * 4
                out[y * width + x] = 0.299 * Float(p[2]) + 0.587 * Float(p[1]) + 0.114 * Float(p[0])
            }
        }
        return out
    }

    /// Every frame of an animated GIF, shrunk to the analysis size as gray, with the second at which
    /// each is shown (from the GIF's own delays).
    static func grayFrames(ofGIF url: URL) -> (frames: [[Float]], times: [Double]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return ([], []) }
        var frames: [[Float]] = [], times: [Double] = []
        var clock = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            var gray = [UInt8](repeating: 0, count: width * height)
            let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { continue }
            frames.append(gray.map(Float.init))
            times.append(clock)
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            clock += (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        }
        return (frames, times)
    }
}

/// Phase correlation between two small gray images, with sub-pixel peaks.
final class PhaseCorrelator {
    private let n = OutputMotion.fft
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    init() {
        log2n = vDSP_Length(log2(Double(OutputMotion.fft)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        // No window: the background sits at the edges, and a window would weight the middle of the
        // frame, where the subject is, so the path would follow the subject instead of the scene.
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// The 2D spectrum of `image` (mean removed).
    func spectrum(of image: [Float]) -> (re: [Float], im: [Float]) {
        let w = OutputMotion.width, h = OutputMotion.height
        let mean = image.reduce(0, +) / Float(image.count)
        var re = [Float](repeating: 0, count: n * n), im = [Float](repeating: 0, count: n * n)
        for y in 0..<h { for x in 0..<w { re[y * n + x] = image[y * w + x] - mean } }
        transform(&re, &im, direction: FFTDirection(kFFTDirection_Forward))
        return (re, im)
    }

    /// How far the picture of `a` has moved relative to `b`, in pixels (x right, y down).
    func shift(of a: (re: [Float], im: [Float]), relativeTo b: (re: [Float], im: [Float])) -> SIMD2<Double> {
        var re = [Float](repeating: 0, count: n * n), im = [Float](repeating: 0, count: n * n)
        for i in 0..<(n * n) {
            // A x conj(B), normalized to unit magnitude: only the phase, which carries the shift.
            let r = a.re[i] * b.re[i] + a.im[i] * b.im[i]
            let m = a.im[i] * b.re[i] - a.re[i] * b.im[i]
            let magnitude = (r * r + m * m).squareRoot() + 1e-9
            re[i] = r / magnitude
            im[i] = m / magnitude
        }
        transform(&re, &im, direction: FFTDirection(kFFTDirection_Inverse))

        var best: Float = -.infinity, bx = 0, by = 0
        for y in 0..<n { for x in 0..<n where re[y * n + x] > best { best = re[y * n + x]; bx = x; by = y } }
        func at(_ x: Int, _ y: Int) -> Float { re[((y + n) % n) * n + ((x + n) % n)] }
        // Parabola through the peak and its neighbours, for a position finer than a pixel.
        func refine(_ minus: Float, _ center: Float, _ plus: Float) -> Double {
            let denominator = minus - 2 * center + plus
            return abs(denominator) < 1e-12 ? 0 : Double(0.5 * (minus - plus) / denominator)
        }
        var dx = Double(bx) + refine(at(bx - 1, by), at(bx, by), at(bx + 1, by))
        var dy = Double(by) + refine(at(bx, by - 1), at(bx, by), at(bx, by + 1))
        if dx > Double(n) / 2 { dx -= Double(n) }
        if dy > Double(n) / 2 { dy -= Double(n) }
        return SIMD2(dx, dy)
    }

    private func transform(_ re: inout [Float], _ im: inout [Float], direction: FFTDirection) {
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft2d_zip(setup, &split, 1, vDSP_Stride(n), log2n, log2n, direction)
            }
        }
    }
}
