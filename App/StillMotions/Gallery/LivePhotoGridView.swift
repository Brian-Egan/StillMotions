import Photos
import SwiftUI

/// The grid of Live Photos, newest first. Tapping one opens the editor with that asset.
struct LivePhotoGridView: View {
    @State private var library = LivePhotoLibrary()
    @State private var loader = ThumbnailLoader()

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        Group {
            if library.count == 0 {
                ContentUnavailableView(
                    "No Live Photos",
                    systemImage: "livephoto",
                    description: Text("Live Photos you take will appear here.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(0..<library.count, id: \.self) { index in
                            let asset = library.asset(at: index)
                            NavigationLink(value: Route.editor(assetID: asset.localIdentifier)) {
                                LivePhotoCell(asset: asset)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .environment(loader)
        .overlay(alignment: .bottom) { RequestCountsOverlay(loader: loader) }
    }
}

/// One square cell. It loads its thumbnail only while it is actually visible in the scroll view,
/// and its request is cancelled the moment it scrolls out.
///
/// That is tied to scroll visibility on purpose. A plain `.task` on a lazy grid's cell was
/// measured NOT to be cancelled when the cell scrolls away: with each thumbnail held in flight for
/// 2.5 s, a scroll up and down started 39 more requests and cancelled none (UI test, iOS 27
/// simulator). `onScrollVisibilityChange` reports the cell really entering and leaving view; that
/// flips the task's identity, SwiftUI cancels the old task, and the task's cancellation handler
/// cancels its PhotoKit request. The same test passes with this version.
private struct LivePhotoCell: View {
    let asset: PHAsset
    @Environment(ThumbnailLoader.self) private var loader
    @Environment(\.displayScale) private var displayScale
    @State private var image: Image?
    @State private var loadedAssetID: String?
    @State private var isVisible = false

    private struct LoadKey: Equatable {
        let assetID: String
        let visible: Bool
    }

    var body: some View {
        Color(white: 0.5, opacity: 0.15)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    ZStack {
                        if let image {
                            image.resizable().scaledToFill()
                                .frame(width: proxy.size.width, height: proxy.size.height)
                        }
                    }
                    .task(id: LoadKey(assetID: asset.localIdentifier, visible: isVisible)) {
                        // The library changed under this cell: show nothing until the new photo loads.
                        if loadedAssetID != asset.localIdentifier {
                            image = nil
                            loadedAssetID = nil
                        }
                        guard isVisible, loadedAssetID == nil else { return }
                        let side = max(proxy.size.width, 1) * displayScale
                        if let loaded = await loader.thumbnail(for: asset, pixelSize: CGSize(width: side, height: side)) {
                            image = loaded
                            loadedAssetID = asset.localIdentifier
                        }
                    }
                }
            }
            .clipped()
            .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
            .accessibilityLabel(asset.creationDate.map { "Live Photo from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Live Photo")
            .accessibilityIdentifier("livePhotoCell")
    }
}

/// Request counts for instrumentation, in debug builds only.
private struct RequestCountsOverlay: View {
    let loader: ThumbnailLoader

    var body: some View {
        #if DEBUG
        Text("thumbnails: started \(loader.startedCount), finished \(loader.finishedCount), cancelled \(loader.cancelledCount), active \(loader.activeCount)")
            .font(.caption2.monospacedDigit())
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 4)
            .accessibilityIdentifier("requestCounts")
        #else
        EmptyView()
        #endif
    }
}
