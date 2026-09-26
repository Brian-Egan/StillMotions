import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// A deterministic pseudo-random generator so fixture jitter is reproducible byte-for-byte
/// across runs and machines. Not for anything security-sensitive — just fixed, portable
/// noise for synthetic motion.
struct DeterministicRNG {
    private var state: UInt64

    init(seed: UInt64) {
        // Avoid a zero state, which would make xorshift produce all zeros forever.
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func nextUnit() -> Double {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 0x2545_F491_4F6C_DD1D
        return Double(value >> 11) * (1.0 / Double(1 << 53))
    }

    /// A uniform value in `-magnitude...magnitude`.
    mutating func nextSigned(magnitude: Double) -> Double {
        (nextUnit() * 2.0 - 1.0) * magnitude
    }
}

/// The large, richly textured scene every fixture's camera moves over. Bigger than any
/// output frame so a translate/rotate/scale camera move always samples real content —
/// never black edges introduced by the generator itself.
enum SyntheticCanvas {
    /// Margin added on every side of the output frame size, generous enough for every
    /// fixture's motion budget (largest is `parallax`'s foreground layer).
    static let margin = 220

    static func background(outputSize: CGSize) -> CIImage {
        let size = CGSize(width: outputSize.width + CGFloat(margin) * 2, height: outputSize.height + CGFloat(margin) * 2)
        let extent = CGRect(origin: .zero, size: size)

        let checker = CIFilter.checkerboardGenerator()
        checker.center = CGPoint(x: size.width / 2, y: size.height / 2)
        checker.color0 = CIColor(red: 0.82, green: 0.84, blue: 0.86)
        checker.color1 = CIColor(red: 0.30, green: 0.34, blue: 0.40)
        checker.width = 240
        checker.sharpness = 1

        let gradient = CIFilter.smoothLinearGradient()
        gradient.point0 = CGPoint(x: 0, y: 0)
        gradient.point1 = CGPoint(x: size.width, y: size.height)
        gradient.color0 = CIColor(red: 0.95, green: 0.55, blue: 0.20, alpha: 0.35)
        gradient.color1 = CIColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 0.35)

        var image = checker.outputImage!.cropped(to: extent)
        let gradientImage = gradient.outputImage!.cropped(to: extent)
        image = gradientImage.composited(over: image)

        // A handful of fixed, distinctly-colored/sized circles so no two crops of the
        // canvas look alike — breaks the translational ambiguity a pure checkerboard tile
        // would otherwise have at multiples of its tile width.
        let landmarks: [(CGPoint, CGFloat, CIColor)] = [
            (CGPoint(x: 180, y: 220), 90, CIColor(red: 0.85, green: 0.15, blue: 0.15)),
            (CGPoint(x: size.width - 260, y: 180), 70, CIColor(red: 0.15, green: 0.65, blue: 0.25)),
            (CGPoint(x: size.width * 0.5, y: size.height - 200), 110, CIColor(red: 0.95, green: 0.85, blue: 0.10)),
            (CGPoint(x: 300, y: size.height - 320), 55, CIColor(red: 0.55, green: 0.20, blue: 0.75)),
            (CGPoint(x: size.width - 180, y: size.height * 0.55), 65, CIColor(red: 0.10, green: 0.55, blue: 0.75)),
        ]
        for (center, radius, color) in landmarks {
            let circle = CIFilter.radialGradient()
            circle.center = center
            circle.radius0 = Float(radius) * 0.85
            circle.radius1 = Float(radius)
            circle.color0 = color
            circle.color1 = color.withAlphaComponent(0)
            let circleImage = circle.outputImage!.cropped(to: extent)
            image = circleImage.composited(over: image)
        }

        return image.cropped(to: extent)
    }

    /// A sparse layer of opaque shapes on a transparent field, used as the near layer in
    /// the `parallax` fixture and as the independently-moving object in `moving-subject`.
    static func foregroundObject(size: CGSize, rect: CGRect, color: CIColor) -> CIImage {
        let extent = CGRect(origin: .zero, size: size)
        let solid = CIImage(color: color).cropped(to: rect)
        let transparent = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        return solid.composited(over: transparent)
    }

    /// A handful of large, distinctly-colored opaque blocks on a transparent field — the
    /// `parallax` fixture's near layer, translating faster than the background so no
    /// single homography fits both.
    static func nearLayer(outputSize: CGSize) -> CIImage {
        let size = CGSize(width: outputSize.width + CGFloat(margin) * 2, height: outputSize.height + CGFloat(margin) * 2)
        let extent = CGRect(origin: .zero, size: size)
        var image = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: extent)
        let blocks: [(CGRect, CIColor)] = [
            (CGRect(x: 260, y: 300, width: 220, height: 340), CIColor(red: 0.95, green: 0.25, blue: 0.15)),
            (CGRect(x: size.width - 560, y: 220, width: 260, height: 260), CIColor(red: 0.15, green: 0.85, blue: 0.35)),
            (CGRect(x: size.width * 0.42, y: size.height - 420, width: 300, height: 260), CIColor(red: 0.20, green: 0.35, blue: 0.95)),
        ]
        for (rect, color) in blocks {
            let solid = CIImage(color: color).cropped(to: rect)
            image = solid.composited(over: image)
        }
        return image
    }
}

extension CIColor {
    func withAlphaComponent(_ alpha: CGFloat) -> CIColor {
        CIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
