import os
import Photos
import StillMotionsPipeline
import SwiftUI

/// Loads grid thumbnails and cancels the request when its cell scrolls away.
///
/// The cancellation is built into the structure: a cell loads inside a SwiftUI `.task`, SwiftUI
/// cancels that task when the cell disappears, and `withTaskCancellationHandler` turns the task's
/// cancellation into `cancelImageRequest`. `requests` counts what started, finished and was
/// cancelled, and each event is logged, so the behaviour can be read off a run (subsystem
/// `com.began.Still-Motions`, category `gallery`).
@MainActor
@Observable
final class ThumbnailLoader {
    private let manager = PHCachingImageManager()
    private let log = Logger(subsystem: "com.began.Still-Motions", category: "gallery")
    @ObservationIgnored let requests = InFlightRequests<String>()

    /// Live counts for instrumentation; cells and tests can read them.
    private(set) var startedCount = 0
    private(set) var finishedCount = 0
    private(set) var cancelledCount = 0
    private(set) var activeCount = 0

    /// Debug builds only: `-slowThumbnails` holds every thumbnail for a moment, so a UI test can
    /// scroll while requests are genuinely in flight. On a simulator they otherwise finish in
    /// milliseconds, before a cell can leave the screen, and there would be nothing to cancel.
    private let artificialDelay: Duration?

    init() {
        #if DEBUG
        artificialDelay = ProcessInfo.processInfo.arguments.contains("-slowThumbnails") ? .milliseconds(2500) : nil
        #else
        artificialDelay = nil
        #endif
    }

    /// A square thumbnail, or `nil` if the request was cancelled or failed.
    func thumbnail(for asset: PHAsset, pixelSize: CGSize) async -> Image? {
        let id = asset.localIdentifier
        let handle = RequestHandle()

        let image: Image? = await withTaskCancellationHandler {
            let loaded: Image? = await withCheckedContinuation { continuation in
                let options = PHImageRequestOptions()
                // One callback, not two: the default (opportunistic) delivery calls back with a
                // degraded image and then the final one, and resuming a continuation twice crashes.
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = true

                let started = requests.begin(id) {
                    let requestID = manager.requestImage(
                        for: asset, targetSize: pixelSize, contentMode: .aspectFill, options: options
                    ) { image, info in
                        let cancelled = (info?[PHImageCancelledKey] as? Bool) ?? false
                        continuation.resume(returning: cancelled ? nil : image.map { Image(uiImage: $0) })
                    }
                    handle.set(requestID)
                    return { [manager] in manager.cancelImageRequest(requestID) }
                }
                if started {
                    startedCount += 1
                    activeCount = requests.activeCount
                    log.debug("thumbnail request started (active \(self.requests.activeCount))")
                } else {
                    // Already loading for this asset; this duplicate has nothing to wait for.
                    continuation.resume(returning: nil)
                }
            }
            // Cancelling the task ends this sleep at once, so a held request is still cancellable.
            if let artificialDelay { try? await Task.sleep(for: artificialDelay) }
            return loaded
        } onCancel: {
            // May run on any thread, so the actual cancel hops to the main actor.
            Task { @MainActor [weak self] in self?.cancel(id) }
        }

        if requests.isActive(id) {
            requests.finish(id)
            finishedCount += 1
        }
        activeCount = requests.activeCount
        return image
    }

    private func cancel(_ id: String) {
        guard requests.isActive(id) else { return }
        requests.cancel(id)
        cancelledCount += 1
        activeCount = requests.activeCount
        log.debug("thumbnail request cancelled (active \(self.requests.activeCount))")
    }

    /// Holds the PhotoKit request id from the closure that makes it to the one that cancels it.
    private final class RequestHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var id: PHImageRequestID?
        func set(_ value: PHImageRequestID) { lock.withLock { id = value } }
    }
}
