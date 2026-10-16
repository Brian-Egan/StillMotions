import SwiftUI
import StillMotionsPipeline

/// Placeholder for the editor (#25). It also proves the app is wired to the pipeline package:
/// the line below is computed by the package, from the user's saved default preset.
struct EditorView: View {
    let assetID: String
    @Environment(AppSettings.self) private var settings

    private var previewSize: String {
        // A made-up 1920x1080 crop, sized the way an export at the default preset would be.
        let size = OutputSize.size(
            forCrop: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            longEdge: settings.values.sizePreset.longEdge
        )
        return "\(Int(size.width)) x \(Int(size.height))"
    }

    var body: some View {
        List {
            Section("Editor placeholder") {
                LabeledContent("Asset", value: assetID)
            }
            Section("From the pipeline package") {
                LabeledContent("Default preset", value: settings.values.sizePreset.rawValue.capitalized)
                LabeledContent("1920x1080 crop becomes", value: previewSize)
                LabeledContent("GIF delay", value: "\(settings.values.gifFrameRate.centiseconds) cs per frame")
                LabeledContent("Default mode", value: settings.values.mode.rawValue.capitalized)
                LabeledContent("Default format", value: settings.values.format.rawValue.uppercased())
            }
        }
        .navigationTitle("Editor")
        .navigationBarTitleDisplayMode(.inline)
    }
}
