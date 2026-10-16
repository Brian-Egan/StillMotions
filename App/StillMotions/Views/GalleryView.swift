import SwiftUI

/// Placeholder for the Live Photo grid (#23). It already handles photo-library authorization,
/// which is the part this issue owns: ask on first use, and on denial explain and offer Settings
/// rather than show an empty grid.
struct GalleryView: View {
    @Environment(PhotoLibraryAccess.self) private var photoAccess

    var body: some View {
        Group {
            switch photoAccess.state {
            case .notDetermined:
                ProgressView("Waiting for photo access…")
            case .authorized, .limited:
                galleryPlaceholder
            case .denied, .restricted:
                PhotoAccessDeniedView(restricted: photoAccess.state == .restricted)
            }
        }
        // First use: ask when the gallery appears, not at launch before there is anything to explain.
        .task { await photoAccess.requestIfNeeded() }
    }

    private var galleryPlaceholder: some View {
        List {
            Section {
                NavigationLink("Open the editor", value: Route.editor(assetID: "placeholder-asset"))
            } footer: {
                Text("The Live Photo grid arrives with the gallery. This row stands in for a photo.")
            }
        }
    }
}
