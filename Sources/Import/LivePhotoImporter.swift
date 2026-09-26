import AVFoundation
import Foundation
import ImageIO
import PipelineCore

/// File-based import of a Live Photo: a HEIC + MOV pair from the filesystem, with no
/// PhotoKit dependency (PRD R-4). The PhotoKit path lives in the app and adapts into this
/// same file-based input.
///
/// Reference frame index: derived from the HEIC's EXIF `DateTimeOriginal` (plus
/// `SubsecTimeOriginal`) against the MOV's own creation date — both are real capture-time
/// metadata the camera writes for the same physical instant. An alternative was tried
/// first: QuickTime's documented `com.apple.quicktime.still-image-time` timed-metadata
/// convention. That didn't round-trip reliably through `AVAssetWriterInputMetadataAdaptor`
/// when built and read back in isolation (no real Live Photo available to check the write
/// side against), so this uses the simpler EXIF-vs-creation-date delta instead, which is
/// independently verifiable with standard APIs. Both timestamps are treated as UTC; EXIF
/// `DateTimeOriginal` carries no timezone field, so if a real Live Photo's still was tagged
/// in local time with an offset from the video's UTC creation date, this will need
/// revisiting once checked against a real export — flagged here rather than assumed.
public enum LivePhotoImporter {
    public static func describeClip(heicURL: URL, movURL: URL) async throws -> ClipDescriptor {
        guard FileManager.default.fileExists(atPath: heicURL.path) else {
            throw ClipImportError.missingFile(heicURL)
        }
        guard FileManager.default.fileExists(atPath: movURL.path) else {
            throw ClipImportError.missingFile(movURL)
        }
        guard let source = CGImageSourceCreateWithURL(heicURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0
        else {
            throw ClipImportError.unreadableStill(heicURL)
        }

        let asset = AVURLAsset(url: movURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw ClipImportError.noVideoTrack(movURL)
        }

        let size = try await track.load(.naturalSize)
        let frameRate = Double(try await track.load(.nominalFrameRate))
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        let frameCount = try streamedFrameCount(asset: asset, track: track)

        let offsetSeconds = try await stillOffsetSeconds(heicURL: heicURL, asset: asset)
        let referenceFrameIndex = frameIndex(atSeconds: offsetSeconds, frameCount: frameCount, frameRate: frameRate, duration: duration)

        return ClipDescriptor(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            frameCount: frameCount,
            sourceFrameRate: frameRate,
            duration: duration,
            referenceFrameIndex: referenceFrameIndex
        )
    }

    /// Counts frames by decoding, the same path `FrameSequence` streams through — see its
    /// doc comment for why this, and not the compressed sample count, is the source of
    /// truth on this toolchain.
    private static func streamedFrameCount(asset: AVAsset, track: AVAssetTrack) throws -> Int {
        var count = 0
        for _ in try FrameSequence.make(asset: asset, track: track) {
            count += 1
        }
        return count
    }

    /// The still's capture time minus the video's creation date, in seconds. `nil` when
    /// either timestamp is missing — not every MOV/HEIC pair carries them, and a missing
    /// marker should be visibly "no marker found" (falls back to frame 0), not a guess.
    private static func stillOffsetSeconds(heicURL: URL, asset: AVAsset) async throws -> Double? {
        guard let stillDate = exifCaptureDate(at: heicURL) else { return nil }
        guard let creationItem = try await asset.load(.creationDate),
              let movieDate = try await creationItem.load(.dateValue)
        else { return nil }
        return stillDate.timeIntervalSince(movieDate)
    }

    private static func exifCaptureDate(at url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let dateTimeOriginal = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let baseDate = formatter.date(from: dateTimeOriginal) else { return nil }

        var subseconds: TimeInterval = 0
        if let subsecString = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
           let subsecValue = Double(subsecString)
        {
            let digits = subsecString.count
            subseconds = subsecValue / pow(10, Double(digits))
        }
        return baseDate.addingTimeInterval(subseconds)
    }

    /// PRD R-4 wants a frame index, not a time offset. Falls back to frame 0 — deliberately
    /// not the midpoint, so a missing marker reads as "no marker found" rather than a
    /// plausible-looking guess (acceptance criterion for #8).
    private static func frameIndex(atSeconds seconds: Double?, frameCount: Int, frameRate: Double, duration: Double) -> Int {
        guard let seconds, frameRate > 0, frameCount > 0 else { return 0 }
        let clamped = min(max(seconds, 0), duration)
        let index = Int((clamped * frameRate).rounded())
        return min(max(index, 0), frameCount - 1)
    }
}
