import AVFoundation
import CoreGraphics
import ImageIO

/// How a video track's STORED pixels must be turned to appear upright.
///
/// Real Live Photo videos store pixels in sensor orientation (landscape) and carry the rotation
/// in the track's `preferredTransform`. A portrait capture is stored sideways with a 90 degree
/// transform. Anything that reads raw pixels without applying it shows the scene rotated, so the
/// importer applies it once, at decode, and everything downstream (crop, presets, GIFs, previews)
/// works on what the viewer sees.
///
/// Cases are named for the EXIF-style direction, which is also what Core Image's `oriented`
/// understands: `.right` means "rotate 90 degrees clockwise to display", which is a portrait
/// capture with the home button below.
public enum TrackOrientation: Equatable {
    case up
    case right
    case down
    case left

    /// From a track's `preferredTransform`. Only the four rotations cameras produce are
    /// recognised; a mirrored or non-right-angle transform is treated as `.up` rather than
    /// guessed at.
    public init(transform: CGAffineTransform) {
        let a = Int(transform.a.rounded()), b = Int(transform.b.rounded())
        let c = Int(transform.c.rounded()), d = Int(transform.d.rounded())
        switch (a, b, c, d) {
        case (0, 1, -1, 0): self = .right
        case (-1, 0, 0, -1): self = .down
        case (0, -1, 1, 0): self = .left
        default: self = .up
        }
    }

    public static func load(from track: AVAssetTrack) async throws -> TrackOrientation {
        TrackOrientation(transform: try await track.load(.preferredTransform))
    }

    /// Synchronous read for `FrameSequence.make`, which is not `async`. The property is
    /// deprecated in favour of `load(.preferredTransform)`, which `load(from:)` uses; the value is
    /// the same and a track's transform is available as soon as the track exists.
    static func current(of track: AVAssetTrack) -> TrackOrientation {
        TrackOrientation(transform: track.preferredTransform)
    }

    var swapsAxes: Bool { self == .right || self == .left }

    var cgOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .right: return .right
        case .down: return .down
        case .left: return .left
        }
    }

    /// The size once turned upright, given the track's stored (`naturalSize`) size.
    public func uprightSize(_ stored: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: stored.height, height: stored.width) : stored
    }
}
