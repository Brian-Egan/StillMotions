import SwiftUI

/// What the navigation stack can show above the gallery.
enum Route: Hashable {
    case editor(assetID: String)
    /// A photo shared to StillMotions from Photos (issue #37).
    case shared(id: UUID)
    case settings
}

struct RootView: View {
    @Environment(PhotoLibraryAccess.self) private var photoAccess
    @Environment(PendingShares.self) private var pending
    @Environment(\.scenePhase) private var scenePhase
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                PendingSharesStrip()
                GalleryView()
            }
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
                    EditorView(source: .library(assetID: assetID))
                case .shared(let id):
                    EditorView(source: .shared(id: id))
                case .settings:
                    SettingsView()
                }
            }
        }
        // Whenever the app comes to the front: coming back from the Settings app after granting access should
        // unlock the gallery, and anything the share extension staged since last time is picked up. The
        // extension cannot open this app itself, so this is the only moment it can be found (decision 0003).
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            photoAccess.refresh()
            Task {
                let arrived = await pending.refresh()
                // One photo shared: go straight to it. Several: they wait at the top of the gallery. Never
                // pull someone out of the screen they are on.
                if arrived.count == 1, path.isEmpty { path.append(.shared(id: arrived[0])) }
            }
        }
    }
}
