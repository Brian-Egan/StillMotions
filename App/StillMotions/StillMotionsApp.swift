import StillMotionsPipeline
import SwiftUI

@main
struct StillMotionsApp: App {
    // Created once and shared through the environment, so every screen sees the same state.
    @State private var settings = AppSettings()
    @State private var photoAccess = PhotoLibraryAccess()

    init() {
        // A run that was killed mid-load can leave staged folders behind; clear them before anything new is staged.
        LivePhotoStager().purgeLeftovers()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(photoAccess)
        }
    }
}
