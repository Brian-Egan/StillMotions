import XCTest
@testable import StillMotionsPipeline

/// #37: the app's pick-up of what the share extension staged. The issue's properties, as tests: idempotent on
/// the manifest id across a crash, a MOVE and not a copy, old and corrupt items discarded, the container left
/// empty, and several shares showing newest first.
final class DropBoxDrainTests: XCTestCase {
    var base: URL!
    var dropBox: DropBox!
    var drain: DropBoxDrain!
    var sources: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("drain-test-\(UUID().uuidString)", isDirectory: true)
        let container = base.appendingPathComponent("AppGroup/DropBox", isDirectory: true)
        let store = base.appendingPathComponent("App/SharedItems", isDirectory: true)
        sources = base.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        dropBox = DropBox(root: container)
        drain = DropBoxDrain(dropBox: dropBox, store: store)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: base) }

    func stage(at date: Date = Date(), size: Int = 4096) throws -> DropBox.Manifest {
        let staging = try dropBox.begin()
        let still = sources.appendingPathComponent("\(UUID().uuidString).HEIC"), video = sources.appendingPathComponent("\(UUID().uuidString).MOV")
        try Data(repeating: 1, count: size).write(to: still)
        try Data(repeating: 2, count: size).write(to: video)
        return try staging.finish(stillFile: try staging.copy(still, as: .still), videoFile: try staging.copy(video, as: .video), now: date)
    }

    /// Everything left in the shared container.
    func containerEntries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dropBox.root.path)) ?? []).sorted()
    }

    func fileIdentity(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? UInt64) ?? nil
    }

    // MARK: - Ingest

    func testOneShareIsIngestedAndTheContainerIsLeftEmpty() throws {
        let manifest = try stage()
        let report = drain.run()
        XCTAssertEqual(report.ingested, [manifest.id])
        XCTAssertEqual(containerEntries(), [], "staged files are deleted once ingested: the container is empty")
        let items = drain.items()
        XCTAssertEqual(items.map(\.id), [manifest.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].stillURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: items[0].videoURL.path))
    }

    func testIngestingIsAMoveNotACopy() throws {
        let manifest = try stage(size: 1_000_000)
        let before = fileIdentity(dropBox.videoURL(of: manifest))
        _ = drain.run()
        // The same file, not a copy of it: a rename on one volume, so a long video costs no memory and no time.
        XCTAssertNotNil(before)
        XCTAssertEqual(fileIdentity(try XCTUnwrap(drain.items().first).videoURL), before, "the staged file itself was moved")
    }

    func testRunningAgainDoesNotIngestItTwice() throws {
        let manifest = try stage()
        XCTAssertEqual(drain.run().ingested, [manifest.id])
        XCTAssertEqual(drain.run().ingested, [], "nothing new the second time")
        XCTAssertEqual(drain.items().map(\.id), [manifest.id], "exactly once")
    }

    func testACrashBeforeTheMoveLosesNothing() throws {
        // Killed before ingest began: the share is still in the container. The next drain ingests it once.
        let manifest = try stage()
        XCTAssertEqual(drain.items(), [])
        XCTAssertEqual(drain.run().ingested, [manifest.id])
        XCTAssertEqual(drain.items().count, 1)
    }

    func testACrashBetweenACopyAndTheDeleteDoesNotDuplicate() throws {
        // Where a move needs a copy (different volumes) a crash can leave the share in BOTH places.
        let manifest = try stage()
        let inStore = drain.store.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: drain.store, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dropBox.folder(for: manifest.id), to: inStore)

        let report = drain.run()
        XCTAssertEqual(report.ingested, [], "this run did not ingest it: it was already ingested")
        XCTAssertEqual(containerEntries(), [], "the leftover original is cleared")
        XCTAssertEqual(drain.items().map(\.id), [manifest.id], "and it appears exactly once")
    }

    func testSeveralSharesAllArriveNewestFirst() throws {
        let start = Date()
        let a = try stage(at: start.addingTimeInterval(-300))
        let b = try stage(at: start.addingTimeInterval(-200))
        let c = try stage(at: start.addingTimeInterval(-100))
        let report = drain.run(now: start)
        XCTAssertEqual(report.ingested, [a.id, b.id, c.id], "ingested oldest first")
        XCTAssertEqual(drain.items().map(\.id), [c.id, b.id, a.id], "shown newest first")
        XCTAssertEqual(containerEntries(), [])
    }

    // MARK: - Old and broken

    func testAShareOlderThanSevenDaysIsDiscardedWithItsFiles() throws {
        let now = Date()
        let old = try stage(at: now.addingTimeInterval(-8 * 86_400))
        let recent = try stage(at: now.addingTimeInterval(-6 * 86_400))
        let report = drain.run(now: now)
        XCTAssertEqual(report.expired, [old.id])
        XCTAssertEqual(report.ingested, [recent.id], "six days old is still wanted")
        XCTAssertEqual(containerEntries(), [], "the old one is gone with its files")
        XCTAssertEqual(drain.items().map(\.id), [recent.id])
    }

    func testACorruptManifestIsDiscardedNotRetriedForever() throws {
        let manifest = try stage()
        try Data("{not json".utf8).write(to: dropBox.folder(for: manifest.id).appendingPathComponent(DropBox.manifestFileName))
        let report = drain.run()
        XCTAssertEqual(report.discarded, [manifest.id.uuidString])
        XCTAssertEqual(containerEntries(), [], "discarded with its files")
        XCTAssertEqual(drain.run().discarded, [], "and not found again")
        XCTAssertEqual(drain.items(), [])
    }

    func testAManifestNamingMissingFilesIsDiscarded() throws {
        let manifest = try stage()
        try FileManager.default.removeItem(at: dropBox.videoURL(of: manifest))
        XCTAssertEqual(drain.run().discarded, [manifest.id.uuidString])
        XCTAssertEqual(containerEntries(), [])
    }

    func testAShareStillBeingWrittenIsLeftAlone() throws {
        // The extension is mid-copy (no manifest yet) while the app opens: the drain must not clear it.
        let staging = try dropBox.begin()
        let file = sources.appendingPathComponent("a.HEIC"); try Data(repeating: 1, count: 100).write(to: file)
        _ = try staging.copy(file, as: .still)
        XCTAssertEqual(drain.run().discarded, [], "a fresh folder with no manifest may be a share in progress")
        XCTAssertEqual(containerEntries(), [staging.id.uuidString])

        // The same folder an hour later is a share that was killed: cleared.
        let later = Date().addingTimeInterval(3600)
        XCTAssertEqual(drain.run(now: later).discarded, [staging.id.uuidString])
        XCTAssertEqual(containerEntries(), [])
    }

    // MARK: - Using and clearing what was ingested

    func testRemovingAnItemRemovesItsFiles() throws {
        let manifest = try stage()
        _ = drain.run()
        drain.remove(manifest.id)
        XCTAssertEqual(drain.items(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: drain.store.appendingPathComponent(manifest.id.uuidString).path))
    }

    func testItemsNobodyOpenedAreClearedAfterSevenDays() throws {
        let now = Date()
        let manifest = try stage(at: now.addingTimeInterval(-86_400))
        _ = drain.run(now: now)
        XCTAssertEqual(drain.removeExpiredItems(now: now), [], "a day old is fine")
        XCTAssertEqual(drain.removeExpiredItems(now: now.addingTimeInterval(7 * 86_400)), [manifest.id])
        XCTAssertEqual(drain.items(), [])
    }

    func testNothingToDrainIsFine() {
        XCTAssertEqual(drain.run(), DropBoxDrain.Report())
        XCTAssertEqual(drain.items(), [])
    }
}
