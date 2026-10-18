import Foundation

/// How hard a clip is to compress as a GIF, measured from the stabilized preview frames (issue #31).
///
/// File size depends on the pictures: a clip of a plain wall and a clip of leaves in the wind differ
/// by an order of magnitude at the same dimensions and frame count. These numbers let the size
/// estimate see that without encoding anything. They are cheap (a few small frames), and the app
/// and the harness compute them with this one function, so the model is fitted on exactly what the
/// app will measure.
public struct ContentFeatures: Codable, Equatable, Sendable {
    /// Mean absolute brightness gradient per pixel (0...255): how much fine detail a frame has.
    public var detail: Double
    /// Share of pixels with a strong edge (0...1).
    public var edgeDensity: Double
    /// Mean absolute brightness change per pixel between consecutive frames (0...255).
    public var change: Double
    /// Share of pixels that changed visibly between consecutive frames (0...1). A GIF only has to
    /// store the pixels that changed, so this is what makes a still-camera clip small.
    public var changeFraction: Double
    /// Entropy, in bits, of the colors (4 bits per channel): how much palette a frame needs.
    public var colorEntropy: Double

    public init(detail: Double, edgeDensity: Double, change: Double, changeFraction: Double, colorEntropy: Double) {
        self.detail = detail
        self.edgeDensity = edgeDensity
        self.change = change
        self.changeFraction = changeFraction
        self.colorEntropy = colorEntropy
    }

    /// Width the frames are shrunk to before measuring. Small on purpose: fast, and it ignores
    /// sensor noise that the GIF palette throws away anyway.
    public static let sampleWidth = 160
    /// Pairs of consecutive frames measured, spread evenly across the clip.
    public static let samplePairs = 8
    public static let edgeThreshold = 12
    public static let changeThreshold = 6
}
