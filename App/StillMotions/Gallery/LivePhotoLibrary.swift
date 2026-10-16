import Observation
import Photos

/// The user's Live Photos, newest first, kept current as the library changes.
///
/// Only assets with the `.photoLive` subtype are fetched (PRD R-1): the app has nothing to do with
/// a plain still. The fetch result is lazy, so a library of thousands costs nothing until a cell
/// asks for its asset.
@MainActor
@Observable
final class LivePhotoLibrary {
    private(set) var assets: PHFetchResult<PHAsset>
    private var observer: ChangeObserver?

    var count: Int { assets.count }

    func asset(at index: Int) -> PHAsset { assets.object(at: index) }

    init() {
        assets = Self.fetchLivePhotos()
        // A photo taken (or deleted) while the app is open should appear without a relaunch.
        let observer = ChangeObserver { [weak self] change in
            self?.apply(change)
        }
        PHPhotoLibrary.shared().register(observer)
        self.observer = observer
    }

    isolated deinit {
        if let observer { PHPhotoLibrary.shared().unregisterChangeObserver(observer) }
    }

    static func fetchLivePhotos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoLive.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: .image, options: options)
    }

    private func apply(_ change: PHChange) {
        if let details = change.changeDetails(for: assets) {
            assets = details.fetchResultAfterChanges
        }
    }

    /// PhotoKit calls this on an arbitrary queue with a `PHChange` that is not `Sendable`. The
    /// fetch result is only touched on the main actor, so the change is handed over once, whole.
    private final class ChangeObserver: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
        private struct Box: @unchecked Sendable { let change: PHChange }
        private let onChange: @MainActor (PHChange) -> Void

        init(onChange: @escaping @MainActor (PHChange) -> Void) {
            self.onChange = onChange
        }

        func photoLibraryDidChange(_ changeInstance: PHChange) {
            let box = Box(change: changeInstance)
            Task { @MainActor [onChange] in onChange(box.change) }
        }
    }
}
