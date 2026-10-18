import CoreGraphics
import CoreImage
import Foundation
import PipelineCore

extension StabilizedFrameCache {
    /// Measures the content of the part of the frame that will be exported. Reads the cache; renders
    /// nothing from source. Returns nil for a cache with fewer than two frames.
    public func contentFeatures(crop: CGRect, context: CIContext = CIContext()) -> ContentFeatures? {
        guard count >= 2 else { return nil }
        let pairs = min(ContentFeatures.samplePairs, count - 1)
        let starts = (0..<pairs).map { pairs == 1 ? 0 : $0 * (count - 2) / (pairs - 1) }

        var detail = 0.0, edges = 0.0, change = 0.0, changed = 0.0, entropy = 0.0
        for start in starts {
            guard let a = gray(at: start, crop: crop, context: context),
                  let b = gray(at: start + 1, crop: crop, context: context) else { continue }
            let statistics = ContentFeatures.statistics(a, b)
            detail += statistics.detail; edges += statistics.edgeDensity
            change += statistics.change; changed += statistics.changeFraction
            entropy += statistics.colorEntropy
        }
        let n = Double(starts.count)
        return ContentFeatures(detail: detail / n, edgeDensity: edges / n, change: change / n, changeFraction: changed / n, colorEntropy: entropy / n)
    }

    private func gray(at index: Int, crop: CGRect, context: CIContext) -> ContentFeatures.Small? {
        let image = self.image(at: index, sourceRect: crop)
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return ContentFeatures.Small(cg)
    }
}

extension ContentFeatures {
    /// One frame shrunk to `sampleWidth`: its brightness and its quantized colors.
    struct Small {
        let width: Int, height: Int
        var luma: [Int16]
        var colors: [UInt16]

        init?(_ image: CGImage) {
            let width = ContentFeatures.sampleWidth
            let height = max(2, Int((Double(image.height) / Double(max(1, image.width)) * Double(width)).rounded()))
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                ) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            self.width = width
            self.height = height
            luma = []
            colors = []
            luma.reserveCapacity(width * height)
            colors.reserveCapacity(width * height)
            for p in 0..<(width * height) {
                let r = Int(rgba[p * 4]), g = Int(rgba[p * 4 + 1]), b = Int(rgba[p * 4 + 2])
                luma.append(Int16((299 * r + 587 * g + 114 * b) / 1000))
                colors.append(UInt16((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)))
            }
        }
    }

    /// The numbers for one pair of consecutive frames.
    static func statistics(_ a: Small, _ b: Small) -> ContentFeatures {
        let w = a.width, h = a.height
        var gradient = 0, edgeCount = 0
        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let p = Int(a.luma[y * w + x])
                let dx = abs(p - Int(a.luma[y * w + x + 1])), dy = abs(p - Int(a.luma[(y + 1) * w + x]))
                gradient += dx + dy
                if max(dx, dy) > edgeThreshold { edgeCount += 1 }
            }
        }
        let gradientPixels = (w - 1) * (h - 1)

        var diffSum = 0, changedCount = 0
        for k in 0..<(w * h) {
            let d = abs(Int(a.luma[k]) - Int(b.luma[k]))
            diffSum += d
            if d > changeThreshold { changedCount += 1 }
        }

        var histogram = [Int](repeating: 0, count: 4096)
        for c in a.colors { histogram[Int(c)] += 1 }
        let total = Double(a.colors.count)
        var entropy = 0.0
        for count in histogram where count > 0 {
            let p = Double(count) / total
            entropy -= p * log2(p)
        }

        return ContentFeatures(
            detail: Double(gradient) / Double(gradientPixels * 2), edgeDensity: Double(edgeCount) / Double(gradientPixels),
            change: Double(diffSum) / Double(w * h), changeFraction: Double(changedCount) / Double(w * h), colorEntropy: entropy
        )
    }
}
