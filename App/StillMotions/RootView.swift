import SwiftUI

/// What the navigation stack can show above the gallery. The editor takes the asset to edit; for
/// now it is a placeholder identifier, replaced by a real PhotoKit asset in the gallery issue (#23).
enum Route: Hashable {
    case editor(assetID: String)
    case settings
}

struct RootView: View {
    @Environment(PhotoLibraryAccess.self) private var photoAccess
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            GalleryView()
                .navigationTitle("StillMotions")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                            .accessibilityLabel("Settings")
                            .accessibilityIdentifier("openSettings")
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .editor(let assetID):
                        EditorView(assetID: assetID)
                    case .settings:
                        SettingsView()
                    }
                }
        }
        // Coming back from the Settings app after granting access should unlock the gallery.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { photoAccess.refresh() }
        }
    }
}
