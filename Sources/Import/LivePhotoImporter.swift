import AVFoundation
import Foundation
import ImageIO
import PipelineCore

/// File-based import of a Live Photo: a HEIC + MOV pair from the filesystem, with no
/// PhotoKit dependency (PRD R-4). The PhotoKit path lives in the app and adapts into this
/// same file-based input.
///
/// Reference frame index, in order of preference:
///
/// 1. **The movie's own marker.** A real Live Photo's MOV has a timed metadata track whose
///    `com.apple.quicktime.still-image-time` sample sits at the still's exact moment in the movie
///    (measured on real files: e.g. 1.43 s into a 2.97 s clip). This is what Photos itself uses.
/// 2. **EXIF against the movie's creation date**, for files without the track. Both are real
///    capture-time metadata, but the EXIF time is LOCAL time with a separate
///    `OffsetTimeOriginal`, while the movie's date is absolute, so the offset has to be applied
///    (ignoring it put every real clip's still four hours before the movie and clamped it to
///    frame 0). The movie's date is also truncated to whole seconds, so this path is only good to
///    about a second; it exists as a fallback, not the answer.
/// 3. **Frame 0**, deliberately and visibly "no marker found", never a plausible-looking guess.
///
/// Whichever time is found is mapped to the frame with the nearest ACTUAL presentation time,
/// not `time * nominalFrameRate`: real Live Photos are variable frame rate.
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
        let frameTimes = try FrameSequence.presentationTimes(asset: asset, track: track)

        var stillTime = try await stillImageTime(asset: asset)
        if stillTime == nil { stillTime = try await exifStillTime(heicURL: heicURL, asset: asset) }
        let referenceFrameIndex = nearestFrame(to: stillTime, in: frameTimes)
        let frameCount = frameTimes.count

        return ClipDescriptor(
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            frameCount: frameCount,
            sourceFrameRate: frameRate,
            duration: duration,
            referenceFrameIndex: referenceFrameIndex,
            frameTimes: frameTimes
        )
    }

    /// The still's position in the movie from its `still-image-time` metadata track, or `nil`
    /// when the movie has none.
    static func stillImageTime(asset: AVAsset) async throws -> Double? {
        let wanted = "mdta/com.apple.quicktime.still-image-time"
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let formats = try await track.load(.formatDescriptions)
            let identifiers = formats.flatMap { (CMMetadataFormatDescriptionGetIdentifiers($0) as? [String]) ?? [] }
            guard identifiers.contains(wanted) else { continue }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { continue }
            while let group = adaptor.nextTimedMetadataGroup() {
                if group.items.contains(where: { $0.identifier?.rawValue == wanted }) {
                    let start = group.timeRange.start.seconds
                    if start.isFinite { return start }
                }
            }
        }
        return nil
    }

    /// The still's position in the movie from EXIF against the movie's creation date, or `nil`
    /// when either is missing. Not every pair carries them, and a missing marker should be visibly
    /// "no marker found" (frame 0), not a guess.
    private static func exifStillTime(heicURL: URL, asset: AVAsset) async throws -> Double? {
        guard let stillDate = exifCaptureDate(at: heicURL) else { return nil }
        guard let creationItem = try await asset.load(.creationDate),
              let movieDate = try await creationItem.load(.dateValue)
        else { return nil }
        return stillDate.timeIntervalSince(movieDate)
    }

    /// EXIF `DateTimeOriginal` (+ subseconds) as an absolute instant. The EXIF time is local; its
    /// UTC offset is in `OffsetTimeOriginal` (`"-04:00"`). With no offset recorded it is read as
    /// UTC, which is what files written without one (the synthetic fixtures) assume.
    static func exifCaptureDate(at url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let dateTimeOriginal = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let wallClockAsUTC = formatter.date(from: dateTimeOriginal) else { return nil }
        let baseDate = wallClockAsUTC.addingTimeInterval(-offsetSeconds(exif[kCGImagePropertyExifOffsetTimeOriginal] as? String))

        var subseconds: TimeInterval = 0
        if let subsecString = exif[kCGImagePropertyExifSubsecTimeOriginal] as? String,
           let subsecValue = Double(subsecString)
        {
            subseconds = subsecValue / pow(10, Double(subsecString.count))
        }
        return baseDate.addingTimeInterval(subseconds)
    }

    /// `"+05:30"` or `"-04:00"` as seconds east of UTC; 0 for nil or anything unparseable.
    public static func offsetSeconds(_ text: String?) -> TimeInterval {
        guard let text, text.count == 6, let sign = text.first, sign == "+" || sign == "-" else { return 0 }
        let parts = text.dropFirst().split(separator: ":")
        guard parts.count == 2, let hours = Double(parts[0]), let minutes = Double(parts[1]) else { return 0 }
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
    }

    /// PRD R-4 wants a frame index, not a time. The frame whose presentation time is nearest
    /// `seconds`; frame 0 when there is no marker (deliberately not the midpoint, so a missing
    /// marker reads as "no marker found" rather than a plausible-looking guess).
    public static func nearestFrame(to seconds: Double?, in frameTimes: [Double]) -> Int {
        guard let seconds, !frameTimes.isEmpty else { return 0 }
        var best = 0
        for (index, time) in frameTimes.enumerated() where abs(time - seconds) < abs(frameTimes[best] - seconds) {
            best = index
        }
        return best
    }
}
