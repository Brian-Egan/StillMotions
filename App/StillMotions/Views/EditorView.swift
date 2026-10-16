import Photos
import SwiftUI
import StillMotionsPipeline

/// Placeholder for the editor (#25). It also proves the app is wired to the pipeline package:
/// the line below is computed by the package, from the user's saved default preset.
struct EditorView: View {
    let assetID: String
    @Environment(AppSettings.self) private var settings
    @State private var staging: StagingState = .loading(0)

    /// The result of pulling the Live Photo's files out of the library and reading them with the
    /// pipeline's importer. The real editor (#25) will keep the files while it works; this
    /// placeholder checks the path end to end and then cleans up.
    enum StagingState {
        case loading(Double)
        case staged(String)
        case failed(String)
    }

    private var previewSize: String {
        // A made-up 1920x1080 crop, sized the way an export at the default preset would be.
        let size = OutputSize.size(
            forCrop: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            longEdge: settings.values.sizePreset.longEdge
        )
        return "\(Int(size.width)) x \(Int(size.height))"
    }

    /// The asset the gallery handed over, looked up by its PhotoKit identifier.
    private var takenDate: String {
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject
        return asset?.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? "unknown"
    }

    var body: some View {
        List {
            Section("Editor placeholder") {
                LabeledContent("Asset", value: assetID)
                LabeledContent("Taken", value: takenDate)
                    .accessibilityIdentifier("editorTakenDate")
            }
            Section("Live Photo files") {
                switch staging {
                case .loading(let fraction):
                    LabeledContent("Extracting", value: "\(Int(fraction * 100))%")
                case .staged(let summary):
                    Text(summary).accessibilityIdentifier("stagingResult")
                case .failed(let message):
                    Text(message).foregroundStyle(.red).accessibilityIdentifier("stagingResult")
                }
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
        .task(id: assetID) { await stage() }
    }

    /// Extracts the pair, reads it with the importer, reports what it found, and cleans up.
    private func stage() async {
        let loader = PhotoKitLivePhotoLoader()
        do {
            let staged = try await loader.load(assetID: assetID) { fraction in
                Task { @MainActor in staging = .loading(fraction) }
            }
            defer { staged.cleanup() }
            let clip = try await LivePhotoImporter.describeClip(heicURL: staged.stillURL, movURL: staged.videoURL)
            let size = { (url: URL) in (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0 }
            staging = .staged(
                "Staged the \(staged.plan.tier.rawValue) pair: still \(size(staged.stillURL) / 1024) KB, "
                + "video \(size(staged.videoURL) / 1024) KB. \(clip.width)x\(clip.height), \(clip.frameCount) frames, "
                + "reference frame \(clip.referenceFrameIndex). Folders left behind: \(loader.stager.stagedFolderCount() - 1)."
            )
        } catch is CancellationError {
            // The editor closed while loading; the stager has already cleaned up.
        } catch {
            staging = .failed("\(error)")
        }
    }
}
