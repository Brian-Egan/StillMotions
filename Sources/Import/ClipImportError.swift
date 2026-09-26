import Foundation

public enum ClipImportError: Error, CustomStringConvertible {
    case missingFile(URL)
    case unreadableStill(URL)
    case noVideoTrack(URL)
    case readerFailedToStart(Error?)

    public var description: String {
        switch self {
        case .missingFile(let url):
            return "no file at \(url.path)"
        case .unreadableStill(let url):
            return "\(url.path) is not a readable still image"
        case .noVideoTrack(let url):
            return "\(url.path) has no video track"
        case .readerFailedToStart(let error):
            return "could not start reading video: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}
