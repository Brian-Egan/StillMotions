import Foundation

/// Where the photo being edited comes from.
enum EditorSource: Hashable {
    /// A Live Photo in the library: staged through PhotoKit when the editor opens.
    case library(assetID: String)
    /// A photo shared to StillMotions from Photos (issue #36, #37). Its files are already in the app.
    case shared(id: UUID)
}
