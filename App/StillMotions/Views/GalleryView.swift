import SwiftUI

/// The gallery screen: asks for photo access on first use, shows the Live Photo grid once it has it,
/// and on denial explains and offers Settings rather than showing an empty grid.
struct GalleryView: View {
    @Environment(PhotoLibraryAccess.self) private var photoAccess

    var body: some View {
        Group {
            switch photoAccess.state {
            case .notDetermined:
                ProgressView("Waiting for photo access…")
            case .authorized, .limited:
                LivePhotoGridView()
            case .denied, .restricted:
                PhotoAccessDeniedView(restricted: photoAccess.state == .restricted)
            }
        }
        // First use: ask when the gallery appears, not at launch before there is anything to explain.
        .task { await photoAccess.requestIfNeeded() }
    }
}
