import SwiftUI

/// Shown instead of a dead grid when the photo library cannot be read.
struct PhotoAccessDeniedView: View {
    /// True when something other than the user (parental controls, say) blocks access, in which
    /// case the Settings app cannot fix it and offering it would mislead.
    let restricted: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Photo access is off", systemImage: "photo.on.rectangle.angled")
        } description: {
            if restricted {
                Text("Access to your photos is restricted on this device, so StillMotions cannot show your Live Photos.")
            } else {
                Text("StillMotions needs to read your Live Photos to stabilize them. Turn on photo access in Settings.")
            }
        } actions: {
            if !restricted, let url = OpenSettings.url {
                Button("Open Settings") { openURL(url) }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
