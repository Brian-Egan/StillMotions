import CoreVideo
import Foundation

/// A coarse, already-dilated bitmap of "this pixel belongs to a moving subject", kept at a
/// fixed small resolution so the same mask serves every estimation resolution. Coordinates
/// are normalized with a TOP-left origin, matching image rows.
public struct SubjectMask: Equatable, Sendable {
    public static let gridWidth = 480
    public static let gridHeight = 270

    public let cells: [UInt8]

    public init(cells: [UInt8]) {
        precondition(cells.count == Self.gridWidth * Self.gridHeight, "a mask has \(Self.gridWidth * Self.gridHeight) cells")
        self.cells = cells
    }

    /// True when nothing is masked.
    public var isEmpty: Bool { !cells.contains { $0 != 0 } }

    /// Nothing masked.
    public static var empty: SubjectMask { SubjectMask(cells: [UInt8](repeating: 0, count: gridWidth * gridHeight)) }

    /// Everything masked.
    public static var full: SubjectMask { SubjectMask(cells: [UInt8](repeating: 1, count: gridWidth * gridHeight)) }

    /// Cells masked in either.
    public func union(_ other: SubjectMask) -> SubjectMask {
        SubjectMask(cells: zip(cells, other.cells).map { $0 | $1 })
    }

    /// Fraction of the frame that is masked, 0...1.
    public var coverage: Double {
        Double(cells.reduce(0) { $0 + Int($1) }) / Double(cells.count)
    }

    public func contains(nx: Double, ny: Double) -> Bool {
        let x = min(max(Int(nx * Double(Self.gridWidth)), 0), Self.gridWidth - 1)
        let y = min(max(Int(ny * Double(Self.gridHeight)), 0), Self.gridHeight - 1)
        return cells[y * Self.gridWidth + x] != 0
    }

    /// `rawCells` is any bitmap on the fixed grid; the result is dilated by `radius` cells
    /// (each cell is 4 native pixels on a 1920-wide frame). Flow is unreliable right at a
    /// moving boundary, so the exclusion zone has to be a little bigger than the subject.
    public static func dilated(rawCells: [UInt8], radius: Int) -> SubjectMask {
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
    public static func fromSingleChannel(_ buffer: CVPixelBuffer, threshold: Float = 0.5, dilationRadius: Int) throws -> SubjectMask {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SubjectMaskError("mask has no base address") }
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
                    throw SubjectMaskError("unsupported mask pixel format \(format)")
                }
                raw[gy * gridWidth + gx] = on ? 1 : 0
            }
        }
        return dilated(rawCells: raw, radius: dilationRadius)
    }

    /// From an RGBA render where the subject is bright on black.
    public static func fromBrightness(_ buffer: CVPixelBuffer, dilationRadius: Int) throws -> SubjectMask {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SubjectMaskError("mask has no base address") }
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

public struct SubjectMaskError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

extension SubjectMask {
    /// A copy of `buffer` with every masked pixel painted mid-grey. Registration has no way to
    /// exclude a region (decision 0001), so the subject has to be blanked out of the pixels
    /// themselves, which changes the image content: it is the weaker of the two masking paths.
    public func blanking(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var out: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &out)
        guard let copy = out else { throw SubjectMaskError("could not allocate \(width)x\(height) pixel buffer") }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(copy, [])
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(copy, [])
        }
        guard let src = CVPixelBufferGetBaseAddress(buffer), let dst = CVPixelBufferGetBaseAddress(copy) else {
            throw SubjectMaskError("pixel buffer has no base address")
        }
        let srcStride = CVPixelBufferGetBytesPerRow(buffer)
        let dstStride = CVPixelBufferGetBytesPerRow(copy)
        for y in 0..<height {
            let srcRow = src.advanced(by: y * srcStride).assumingMemoryBound(to: UInt8.self)
            let dstRow = dst.advanced(by: y * dstStride).assumingMemoryBound(to: UInt8.self)
            let ny = (Double(y) + 0.5) / Double(height)
            for x in 0..<width {
                let masked = contains(nx: (Double(x) + 0.5) / Double(width), ny: ny)
                for c in 0..<4 {
                    dstRow[x * 4 + c] = masked && c < 3 ? 128 : srcRow[x * 4 + c]
                }
            }
        }
        return copy
    }
}
