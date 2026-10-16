import CoreVideo
import Foundation

extension SubjectMask {
    /// A copy of `buffer` with every masked pixel replaced by a SMOOTH fill of the colors around
    /// it, so the hole has no edges and no texture.
    ///
    /// Why not paint it grey (`blanking`): the hole is in the same place in both pictures being
    /// registered, so whatever is in it votes for "no motion", and a flat patch with a hard edge
    /// votes loudly. Measured on 117 real clips (#19), a grey patch made estimates under-correct:
    /// crop retention went up because less motion was being removed, and leftover background jitter
    /// went up with it (0.5 px to 2.3 px on clips that stabilized fine unmasked). A fill that
    /// continues the surroundings smoothly has nothing to vote with.
    ///
    /// Method: push-pull. Average the known pixels down a pyramid (weights track how much of each
    /// cell is known), then pull the coarse colors back up into the unknown pixels.
    public func inpainting(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var out: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &out)
        guard let result = out else { throw SubjectMaskError("could not allocate \(width)x\(height) pixel buffer") }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(result, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(result, [])
        }
        guard let src = CVPixelBufferGetBaseAddress(buffer), let dst = CVPixelBufferGetBaseAddress(result) else {
            throw SubjectMaskError("pixel buffer has no base address")
        }
        let srcStride = CVPixelBufferGetBytesPerRow(buffer), dstStride = CVPixelBufferGetBytesPerRow(result)

        // Level 0: three color planes and a weight plane (1 = known, 0 = masked).
        var colors = [[Float]](repeating: [Float](repeating: 0, count: width * height), count: 3)
        var weights = [Float](repeating: 1, count: width * height)
        for y in 0..<height {
            let row = src.advanced(by: y * srcStride).assumingMemoryBound(to: UInt8.self)
            let ny = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let i = y * width + x
                if contains(nx: (Double(x) + 0.5) / Double(width), ny: ny) {
                    weights[i] = 0
                } else {
                    for c in 0..<3 { colors[c][i] = Float(row[x * 4 + c]) }
                }
            }
        }

        // Push: halve until a level is tiny, averaging only known pixels.
        struct Level { var width: Int; var height: Int; var colors: [[Float]]; var weights: [Float] }
        var levels = [Level(width: width, height: height, colors: colors, weights: weights)]
        while let top = levels.last, top.width > 4, top.height > 4 {
            let w = (top.width + 1) / 2, h = (top.height + 1) / 2
            var nextColors = [[Float]](repeating: [Float](repeating: 0, count: w * h), count: 3)
            var nextWeights = [Float](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var weightSum: Float = 0
                    var colorSum: (Float, Float, Float) = (0, 0, 0)
                    for dy in 0..<2 { for dx in 0..<2 {
                        let sx = min(top.width - 1, 2 * x + dx), sy = min(top.height - 1, 2 * y + dy)
                        let si = sy * top.width + sx
                        let sw = top.weights[si]
                        weightSum += sw
                        colorSum.0 += top.colors[0][si] * sw; colorSum.1 += top.colors[1][si] * sw; colorSum.2 += top.colors[2][si] * sw
                    } }
                    let i = y * w + x
                    if weightSum > 0 {
                        nextColors[0][i] = colorSum.0 / weightSum; nextColors[1][i] = colorSum.1 / weightSum; nextColors[2][i] = colorSum.2 / weightSum
                    }
                    nextWeights[i] = min(1, weightSum / 4)
                }
            }
            levels.append(Level(width: w, height: h, colors: nextColors, weights: nextWeights))
        }

        // Pull: from the coarsest level down, fill each level's unknown part from the one above.
        for l in stride(from: levels.count - 2, through: 0, by: -1) {
            let coarse = levels[l + 1]
            for y in 0..<levels[l].height {
                for x in 0..<levels[l].width {
                    let i = y * levels[l].width + x
                    let known = levels[l].weights[i]
                    if known >= 1 { continue }
                    // Bilinear read of the coarse level at this pixel's position.
                    let cx = min(max((Float(x) + 0.5) / 2 - 0.5, 0), Float(coarse.width - 1))
                    let cy = min(max((Float(y) + 0.5) / 2 - 0.5, 0), Float(coarse.height - 1))
                    let x0 = Int(cx), y0 = Int(cy), x1 = min(x0 + 1, coarse.width - 1), y1 = min(y0 + 1, coarse.height - 1)
                    let tx = cx - Float(x0), ty = cy - Float(y0)
                    for c in 0..<3 {
                        let top = coarse.colors[c][y0 * coarse.width + x0] * (1 - tx) + coarse.colors[c][y0 * coarse.width + x1] * tx
                        let bottom = coarse.colors[c][y1 * coarse.width + x0] * (1 - tx) + coarse.colors[c][y1 * coarse.width + x1] * tx
                        let up = top * (1 - ty) + bottom * ty
                        levels[l].colors[c][i] = levels[l].colors[c][i] * known + up * (1 - known)
                    }
                    levels[l].weights[i] = 1
                }
            }
        }

        for y in 0..<height {
            let srcRow = src.advanced(by: y * srcStride).assumingMemoryBound(to: UInt8.self)
            let dstRow = dst.advanced(by: y * dstStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                let i = y * width + x
                for c in 0..<3 { dstRow[x * 4 + c] = UInt8(min(255, max(0, levels[0].colors[c][i].rounded()))) }
                dstRow[x * 4 + 3] = srcRow[x * 4 + 3]
            }
        }
        return result
    }
}
