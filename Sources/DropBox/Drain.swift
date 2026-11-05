import Foundation

/// The app's half of the share flow (issue #37, decision 0003): pick up what the extension staged, make it
/// the app's own, and clear anything that cannot be used.
///
/// "Ingest" is a MOVE of the share's whole folder from the shared App Group container into the app's own
/// storage (`store`), which has the same layout, so `DropBox(root: store)` reads it. On one volume that is a
/// rename: atomic, and it keeps the staged file itself (same file, not a copy), so a long video costs no
/// memory and no time. Because it is a rename:
///
///   - a crash before it leaves the share in the container, and the next drain ingests it: not lost;
///   - a crash after it leaves it in the store and not in the container: not duplicated;
///   - where the volumes differ and a copy is needed, a crash between copy and delete leaves it in BOTH, and
///     the next drain sees the store already has that id, deletes the container's copy and does not ingest
///     it again.
///
/// That is idempotent on the manifest's id, which is what decision 0003 asks for.
public struct DropBoxDrain: Sendable {
    /// A share older than this is discarded unopened, so someone who shares repeatedly and never opens the
    /// app cannot grow the container without bound (decision 0003).
    public static let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    /// A folder with no manifest is either a share still being written or one that was killed. It is left
    /// alone this long, so the drain cannot clear a share out from under an extension that is mid-copy.
    public static let unfinishedGrace: TimeInterval = 10 * 60

    public let dropBox: DropBox
    /// The app's own folder for ingested shares.
    public let store: URL

    public init(dropBox: DropBox, store: URL) {
        self.dropBox = dropBox
        self.store = store
    }

    public struct Report: Equatable, Sendable {
        /// Shares moved into the store by THIS run, oldest first.
        public var ingested: [UUID] = []
        /// Shares discarded unopened because they were older than `maximumAge`.
        public var expired: [UUID] = []
        /// Folders cleared because they could not be used (a corrupt manifest, or a share killed part-way).
        public var discarded: [String] = []
        public init() {}
    }

    /// One ingested share, ready to open.
    public struct Item: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let createdAt: Date
        public let stillURL: URL
        public let videoURL: URL
    }

    // MARK: - Draining

    public func run(now: Date = Date()) -> Report {
        var report = Report()
        let fileManager = FileManager.default

        // 1. Folders that are not a usable finished share.
        for folder in dropBox.unfinishedFolders() {
            let manifestExists = fileManager.fileExists(atPath: folder.appendingPathComponent(DropBox.manifestFileName).path)
            // A manifest that is there but cannot be used was written last and atomically, so it is not an
            // in-progress share: clear it now. No manifest may be a share being written: wait.
            let modified = (try? fileManager.attributesOfItem(atPath: folder.path)[.modificationDate] as? Date) ?? nil
            let old = modified.map { now.timeIntervalSince($0) > Self.unfinishedGrace } ?? true
            if manifestExists || old {
                try? fileManager.removeItem(at: folder)
                report.discarded.append(folder.lastPathComponent)
            }
        }

        // 2. Finished shares: discard the old ones, ingest the rest.
        for manifest in dropBox.finishedShares() {
            if now.timeIntervalSince(manifest.createdAt) > Self.maximumAge {
                dropBox.remove(manifest.id)
                report.expired.append(manifest.id)
            } else if ingest(manifest) {
                report.ingested.append(manifest.id)
            }
        }
        return report
    }

    /// Moves one share into the store. Returns whether THIS call ingested it (false when the store already had
    /// it, or the move failed and the share stays where it is to be tried again).
    private func ingest(_ manifest: DropBox.Manifest) -> Bool {
        let fileManager = FileManager.default
        let source = dropBox.folder(for: manifest.id)
        let destination = store.appendingPathComponent(manifest.id.uuidString, isDirectory: true)

        // Already ingested (a crash between a copy and the delete of the original): finish the job.
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: source)
            return false
        }
        do {
            try fileManager.createDirectory(at: store, withIntermediateDirectories: true)
            try fileManager.moveItem(at: source, to: destination)
            return true
        } catch {
            // Leave it in place: it is not lost, and the next drain tries again. (A half-made destination
            // is removed so it cannot be mistaken for a finished ingest.)
            try? fileManager.removeItem(at: destination)
            return false
        }
    }

    // MARK: - What the app has

    /// The ingested shares, newest first (what the person shared last is at the top).
    public func items() -> [Item] {
        let reader = DropBox(root: store)
        return reader.finishedShares().sorted { $0.createdAt > $1.createdAt }.map {
            Item(id: $0.id, createdAt: $0.createdAt, stillURL: reader.stillURL(of: $0), videoURL: reader.videoURL(of: $0))
        }
    }

    /// Removes an ingested share and its files, once the person has opened it or dismissed it.
    public func remove(_ id: UUID) {
        DropBox(root: store).remove(id)
    }

    /// Removes ingested shares nobody opened for `maximumAge`.
    @discardableResult
    public func removeExpiredItems(now: Date = Date()) -> [UUID] {
        let expired = DropBox(root: store).finishedShares().filter { now.timeIntervalSince($0.createdAt) > Self.maximumAge }.map(\.id)
        for id in expired { remove(id) }
        return expired
    }
}
