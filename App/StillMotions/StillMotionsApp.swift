import SwiftUI

// Scaffolding only. The gallery, editor, and export UI arrive in phases 3 to 5.
@main
struct StillMotionsApp: App {
    var body: some Scene {
        WindowGroup {
            PlaceholderView()
        }
    }
}

private struct PlaceholderView: View {
    var body: some View {
        // Replaced by the gallery in the phase-3 app shell issue (PRD R-1).
        Text("StillMotions")
            .font(.largeTitle)
    }
}
