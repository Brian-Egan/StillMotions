import Photos
import StillMotionsPipeline
import SwiftUI

/// The editor: the stabilized preview, looping, with the playback mode and the GIF frame rate
/// switchable while it plays. Trim, crop, the warning and export are later issues (#27 to #33).
struct EditorView: View {
    let assetID: String
    @Environment(AppSettings.self) private var settings
    @State private var model: EditorModel?

    var body: some View {
        Group {
            if let model {
                EditorContent(model: model, assetID: assetID)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Editor")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: assetID) {
            let model = EditorModel(assetID: assetID, defaults: settings.values)
            self.model = model
            await model.load()
        }
        // Frees the cache and removes the extracted files when the editor closes.
        .onDisappear { model?.close() }
    }
}

private struct EditorContent: View {
    @Bindable var model: EditorModel
    let assetID: String

    /// The date the tapped photo was taken, so the screen can show which photo it is.
    private var takenDate: String {
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        return asset?.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "unknown"
    }

    var body: some View {
        VStack(spacing: 16) {
            switch model.phase {
            case .loading(let message):
                Spacer()
                ProgressView(message)
                Spacer()
            case .failed(let message):
                Spacer()
                ContentUnavailableView("Could not open this photo", systemImage: "exclamationmark.triangle", description: Text(message))
                Spacer()
            case .ready:
                PreviewView(model: model)
                    .aspectRatio(preview: model)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                controls
                Text(model.stabilizationStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("stabilizationStatus")
                Spacer(minLength: 0)
            }
            // Which photo this is, for the tap-goes-to-the-right-photo check, and the debug counters.
            Text(takenDate).font(.caption2).foregroundStyle(.tertiary).accessibilityIdentifier("editorTakenDate")
            #if DEBUG
            Text("analyses \(model.analyzeCount), plans \(model.planCount), memory \(MemoryFootprint.megabytes) MB")
                .font(.caption2.monospacedDigit())
                .accessibilityIdentifier("editorCounters")
            #endif
        }
        .padding()
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $model.mode) {
                ForEach(PlaybackMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("modePicker")

            Picker("Frame rate", selection: $model.frameRate) {
                ForEach(GifFrameRate.allCases, id: \.self) { Text(Self.label(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("ratePicker")

            if model.mode == .loop, !model.hasLoop {
                Text("No loop point found, so this plays the whole clip.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private static func label(for rate: GifFrameRate) -> String {
        rate == .fps16_67 ? "16.7 fps" : "\(Int(rate.framesPerSecond)) fps"
    }
}

private extension View {
    /// The preview keeps the crop's own shape rather than stretching to the screen.
    func aspectRatio(preview model: EditorModel) -> some View {
        aspectRatio(model.previewAspectRatio, contentMode: .fit)
    }
}
