import Foundation
import Observation
import StillMotionsPipeline
import os

/// Photos shared to StillMotions from the Photos share sheet, waiting to be opened (issue #37, decision 0003).
///
/// The share extension can only copy files into the App Group container; it cannot open this app. So the app
/// looks there whenever it becomes active (`refresh`), moves what it finds into its own storage, and clears
/// anything old or unusable. All of that, and why it is safe to repeat, is in the package's `DropBoxDrain`,
/// where `swift test` covers it. This class only runs it off the main thread and publishes the result.
@MainActor
@Observable
final class PendingShares {
    /// Shared photos waiting to be opened, newest first.
    private(set) var items: [DropBoxDrain.Item] = []

    @ObservationIgnored private let drain: DropBoxDrain?
    @ObservationIgnored private static let logger = Logger(subsystem: "com.began.Still-Motions", category: "share")

    init() {
        // Without the App Group (an unsigned simulator build, say) there is simply nothing to pick up.
        if let dropBox = DropBox() {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            drain = DropBoxDrain(dropBox: dropBox, store: support.appendingPathComponent("SharedItems", isDirectory: true))
        } else {
            drain = nil
            Self.logger.notice("no App Group container: shared photos cannot be picked up")
        }
    }

    /// Picks up what the extension staged, and returns the ids that arrived in THIS call, oldest first, so
    /// the caller can open the photo straight away when exactly one came.
    @discardableResult
    func refresh() async -> [UUID] {
        guard let drain else { return [] }
        let result = await Task.detached(priority: .userInitiated) { () -> (DropBoxDrain.Report, [DropBoxDrain.Item]) in
            let report = drain.run()
            drain.removeExpiredItems()
            return (report, drain.items())
        }.value
        items = result.1
        let report = result.0
        if !report.ingested.isEmpty || !report.expired.isEmpty || !report.discarded.isEmpty {
            Self.logger.info("picked up \(report.ingested.count) shared, dropped \(report.expired.count) expired and \(report.discarded.count) unusable")
        }
        return report.ingested
    }

    func item(_ id: UUID) -> DropBoxDrain.Item? {
        items.first { $0.id == id }
    }

    /// The photo has been opened (or dismissed): it is no longer waiting. Its files go with it. The photo itself
    /// is still in the library it was shared from.
    func consume(_ id: UUID) {
        guard let drain else { return }
        items.removeAll { $0.id == id }
        Task.detached { drain.remove(id) }
    }
}
