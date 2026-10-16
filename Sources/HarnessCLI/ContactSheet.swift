import AVFoundation
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import StillMotionsPipeline
import UniformTypeIdentifiers

/// A before/after picture of a clip: `count` frames sampled evenly, each shown as the original
/// next to the stabilized, cropped result. The harness writes these so a reviewer LOOKS at the
/// output instead of trusting numbers (PRD R-22): jitter, a drifting horizon or a wrong crop is
/// obvious here and invisible in a median.
enum ContactSheet {
    static let columns = 3
    static let cellWidth = 360
    static let gap = 6
    static let labelHeight = 22
    static let margin = 12

    static func write(
        movieURL: URL,
        path: CameraPath,
        frameCount: Int,
        to url: URL,
        count: Int = 9,
        renderer: StabilizedRenderer = StabilizedRenderer()
    ) async throws {
        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.noVideoTrack(movieURL)
        }
        let natural = try await TrackOrientation.load(from: track).uprightSize(try await track.load(.naturalSize))
        let source = CGSize(width: natural.width.rounded(), height: natural.height.rounded())
        let cell = CGSize(width: Double(cellWidth), height: (Double(cellWidth) * source.height / source.width).rounded())
        let whole = CGRect(origin: .zero, size: source)

        let wanted = (0..<count).map { count == 1 ? 0 : Int((Double($0) * Double(frameCount - 1) / Double(count - 1)).rounded()) }
        var shots: [(index: Int, before: CGImage, after: CGImage)] = []
        let context = CIContext()
        var index = 0
        for frame in try FrameSequence.make(asset: asset, track: track) {
            defer { index += 1 }
            guard wanted.contains(index) else { continue }
            let before = try renderer.render(frame: frame, correction: matrix_identity_float3x3, crop: whole, outputSize: cell)
            let after = try renderer.render(frame: frame, correction: path.corrections[index], crop: path.crop, outputSize: cell)
            func image(_ buffer: CVPixelBuffer) -> CGImage? {
                context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: Int(cell.width), height: Int(cell.height)))
            }
            guard let b = image(before), let a = image(after) else { continue }
            shots.append((index, b, a))
            if index >= (wanted.last ?? 0) { break }
        }

        let pairWidth = Int(cell.width) * 2 + gap
        let rows = (shots.count + columns - 1) / columns
        let width = margin + columns * (pairWidth + margin)
        let height = margin + rows * (Int(cell.height) + labelHeight + margin)
        guard let cg = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw SpikeError("could not create a contact sheet context") }
        cg.setFillColor(CGColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1))
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (n, shot) in shots.enumerated() {
            let row = n / columns, column = n % columns
            let x = margin + column * (pairWidth + margin)
            // CoreGraphics' origin is bottom-left; row 0 goes at the top.
            let top = height - margin - row * (Int(cell.height) + labelHeight + margin)
            let y = top - Int(cell.height)
            cg.draw(shot.before, in: CGRect(x: x, y: y, width: Int(cell.width), height: Int(cell.height)))
            cg.draw(shot.after, in: CGRect(x: x + Int(cell.width) + gap, y: y, width: Int(cell.width), height: Int(cell.height)))
            drawLabel("frame \(shot.index)   original | stabilized", in: cg, at: CGPoint(x: x, y: y - labelHeight + 6))
        }

        guard let sheet = cg.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw SpikeError("could not write \(url.lastPathComponent)") }
        CGImageDestinationAddImage(destination, sheet, nil)
        guard CGImageDestinationFinalize(destination) else { throw SpikeError("could not finalize \(url.lastPathComponent)") }
    }

    private static func drawLabel(_ text: String, in context: CGContext, at point: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 12, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.85, green: 0.85, blue: 0.87, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
