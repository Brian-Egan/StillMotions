import Foundation
import UniformTypeIdentifiers

/// Decides, from the type identifiers a share offers, which pieces to copy (issue #36). Pure, so it is
/// tested here and not by hand in a share sheet.
///
/// Photos offers a Live Photo in one of two shapes: a single Live Photo BUNDLE (a folder holding the still
/// and the movie, `com.apple.live-photo-bundle`), or the still and the movie as separate items. A regular
/// photo has no movie. This works from what the system's type database says each identifier conforms to,
/// not from a list of names.
public enum ShareSource {
    public enum Plan: Equatable, Sendable {
        /// Copy the still and the movie out of this bundle (a folder).
        case bundle(attachment: Int, typeIdentifier: String)
        /// Copy these two attachments.
        case pair(still: Pick, video: Pick)
        case notALivePhoto
    }

    public struct Pick: Equatable, Sendable {
        public let attachment: Int
        public let typeIdentifier: String

        public init(attachment: Int, typeIdentifier: String) {
            self.attachment = attachment
            self.typeIdentifier = typeIdentifier
        }
    }

    /// `attachments[i]` is the list of type identifiers attachment `i` is offered as, in the order the
    /// provider gives them.
    public static func plan(attachments: [[String]]) -> Plan {
        // 1. A Live Photo bundle, if anything offers one.
        for (index, identifiers) in attachments.enumerated() {
            if let bundle = identifiers.first(where: { isLivePhotoBundle($0) }) {
                return .bundle(attachment: index, typeIdentifier: bundle)
            }
        }
        // 2. Otherwise a still and a movie, as separate attachments.
        var still: Pick?, video: Pick?
        for (index, identifiers) in attachments.enumerated() {
            if video == nil, let movie = identifiers.first(where: { conforms($0, to: .movie) }) {
                video = Pick(attachment: index, typeIdentifier: movie)
            } else if still == nil, let image = preferredImage(in: identifiers) {
                still = Pick(attachment: index, typeIdentifier: image)
            }
        }
        if let still, let video { return .pair(still: still, video: video) }
        return .notALivePhoto
    }

    /// The first file in `urls` that is a still image and the first that is a movie, by what their
    /// extensions say they are. Used to pick the two pieces out of a Live Photo bundle's folder.
    public static func stillAndVideo(in urls: [URL]) -> (still: URL, video: URL)? {
        func type(_ url: URL) -> UTType? { UTType(filenameExtension: url.pathExtension) }
        let sorted = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let still = sorted.first(where: { type($0)?.conforms(to: .image) == true }),
              let video = sorted.first(where: { type($0)?.conforms(to: .movie) == true })
        else { return nil }
        return (still, video)
    }

    static func isLivePhotoBundle(_ identifier: String) -> Bool {
        identifier == "com.apple.live-photo-bundle" || conforms(identifier, to: UTType("com.apple.live-photo-bundle"))
    }

    static func conforms(_ identifier: String, to type: UTType?) -> Bool {
        guard let type, let candidate = UTType(identifier) else { return false }
        return candidate.conforms(to: type)
    }

    /// HEIC and HEIF first (what a Live Photo's still is), then any other image type.
    static func preferredImage(in identifiers: [String]) -> String? {
        let images = identifiers.filter { conforms($0, to: .image) }
        return images.first { $0 == "public.heic" || $0 == "public.heif" } ?? images.first
    }
}
