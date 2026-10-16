import SwiftUI

@main
struct StillMotionsApp: App {
    // Created once and shared through the environment, so every screen sees the same state.
    @State private var settings = AppSettings()
    @State private var photoAccess = PhotoLibraryAccess()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(photoAccess)
        }
    }
}
