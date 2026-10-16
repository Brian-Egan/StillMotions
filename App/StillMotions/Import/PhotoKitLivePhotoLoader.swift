import Photos
import StillMotionsPipeline
import UniformTypeIdentifiers

enum PhotoKitLoadError: Error, CustomStringConvertible {
    case assetNotFound(String)

    var description: String {
        switch self {
        case .assetNotFound: return "that photo is no longer in the library"
        }
    }
}

/// The PhotoKit side of getting a Live Photo into the pipeline. Everything that decides what to
/// extract, in what order, and when to clean up lives in the package's `LivePhotoStager`, where
/// tests cover it; this only translates between PhotoKit and those types and does the one call
/// the package cannot make, which is `PHAssetResourceManager.writeData`.
struct PhotoKitLivePhotoLoader {
    let stager: LivePhotoStager

    init(stager: LivePhotoStager = LivePhotoStager()) {
        self.stager = stager
    }

    /// Extracts the Live Photo's still and video to a temporary folder. The caller owns the result
    /// and calls `cleanup()` on it when done; on any error nothing is left behind.
    ///
    /// Network access is allowed, so an iCloud-optimized original is downloaded rather than
    /// failing, and `progress` (0...1) reports that download.
    func load(assetID: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> StagedLivePhoto {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            throw PhotoKitLoadError.assetNotFound(assetID)
        }
        guard asset.mediaSubtypes.contains(.photoLive) else { throw LivePhotoStagingError.notALivePhoto }

        // PhotoKit's resource objects, by the kind we map them to. The first of each kind is used.
        var byKind: [LivePhotoResourceKind: PHAssetResource] = [:]
        var resources: [LivePhotoResource] = []
        for resource in PHAssetResource.assetResources(for: asset) {
            let kind = Self.kind(of: resource.type)
            if byKind[kind] == nil || kind == .other { byKind[kind] = byKind[kind] ?? resource }
            resources.append(LivePhotoResource(kind: kind, filename: Self.filename(of: resource)))
        }
        let lookup = ResourceLookup(byKind: byKind)

        return try await stager.stage(
            resources: resources,
            writer: { resource, destination, progress in
                guard let phResource = lookup.byKind[resource.kind] else {
                    throw LivePhotoStagingError.incompleteResources("the library has no \(resource.kind.rawValue) resource")
                }
                try await Self.write(phResource, to: destination, progress: progress)
            },
            progress: progress
        )
    }

    static func kind(of type: PHAssetResourceType) -> LivePhotoResourceKind {
        switch type {
        case .photo: return .photo
        case .pairedVideo: return .pairedVideo
        case .fullSizePhoto: return .fullSizePhoto
        case .fullSizePairedVideo: return .fullSizePairedVideo
        default: return .other
        }
    }

    /// `filename` and `contentType` are the current API; `originalFilename` and
    /// `uniformTypeIdentifier` are deprecated.
    static func filename(of resource: PHAssetResource) -> String {
        resource.filename ?? "resource.\(resource.contentType.preferredFilenameExtension ?? "bin")"
    }

    /// Writes one resource to a file, allowing an iCloud download.
    ///
    /// **PhotoKit has no way to cancel `writeData`** (only the in-memory `requestData` returns a
    /// cancellable id). So cancelling the task stops WAITING at once, with `CancellationError`, and
    /// the stager deletes the folder; a download already under way may run on in the background
    /// until it ends, and its late completion is ignored.
    private static func write(_ resource: PHAssetResource, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true // fetch an iCloud-optimized original instead of failing
        options.progressHandler = { progress($0) }
        let gate = ResumeOnce()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    gate.finish(error)
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }

    /// PhotoKit resources are not `Sendable`; they are only read after being collected, and the
    /// stager's writer closure has to be, so they travel in this box.
    private struct ResourceLookup: @unchecked Sendable {
        let byKind: [LivePhotoResourceKind: PHAssetResource]
    }

    /// Resumes a continuation exactly once, whether PhotoKit finishes or the task is cancelled
    /// first, in either order. Resuming twice would crash.
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false
        private var cancelledEarly = false

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            let resumeNow: Bool = lock.withLock {
                if cancelledEarly { finished = true; return true }
                self.continuation = continuation
                return false
            }
            if resumeNow { continuation.resume(throwing: CancellationError()) }
        }

        func finish(_ error: Error?) {
            let toResume: CheckedContinuation<Void, Error>? = lock.withLock {
                guard !finished else { return nil }
                finished = true
                defer { continuation = nil }
                return continuation
            }
            if let error { toResume?.resume(throwing: error) } else { toResume?.resume() }
        }

        func cancel() {
            let toResume: CheckedContinuation<Void, Error>? = lock.withLock {
                guard !finished else { return nil }
                guard let continuation else { cancelledEarly = true; return nil }
                finished = true
                self.continuation = nil
                return continuation
            }
            toResume?.resume(throwing: CancellationError())
        }
    }
}
