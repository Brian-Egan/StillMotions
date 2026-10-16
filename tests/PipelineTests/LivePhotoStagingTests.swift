import XCTest
@testable import StillMotionsPipeline

final class LivePhotoStagingTests: XCTestCase {
    var root: URL!
    var stager: LivePhotoStager!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("staging-test-\(UUID().uuidString)", isDirectory: true)
        stager = LivePhotoStager(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    static func resource(_ kind: LivePhotoResourceKind, _ name: String) -> LivePhotoResource {
        LivePhotoResource(kind: kind, filename: name)
    }

    static let originalPair = [
        resource(.photo, "IMG_0001.HEIC"), resource(.pairedVideo, "IMG_0001.MOV"),
    ]
    static let editedPair = [
        resource(.fullSizePhoto, "FullSizeRender.HEIC"), resource(.fullSizePairedVideo, "FullSizeRender.MOV"),
    ]

    /// Records what was written, in order, and writes a small non-empty file for each.
    final class RecordingWriter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var written: [LivePhotoResourceKind] = []
        func write(_ resource: LivePhotoResource, to url: URL, progress: @Sendable (Double) -> Void) async throws {
            progress(0.5)
            try Data("bytes of \(resource.kind.rawValue)".utf8).write(to: url)
            progress(1)
            lock.withLock { written.append(resource.kind) }
        }
    }

    // MARK: - Tier selection

    func testAnUneditedLivePhotoUsesTheOriginalPair() throws {
        let plan = try LivePhotoResourcePlanner.plan(resources: Self.originalPair)
        XCTAssertEqual(plan.tier, .original)
        XCTAssertEqual(plan.still.kind, .photo)
        XCTAssertEqual(plan.video.kind, .pairedVideo)
    }

    func testAnEditedLivePhotoUsesTheFullSizePairForBothComponents() throws {
        // Both generations are present, as on a real edited asset. The edited pair wins as a unit.
        let plan = try LivePhotoResourcePlanner.plan(resources: Self.originalPair + Self.editedPair + [Self.resource(.other, "Adjustments.plist")])
        XCTAssertEqual(plan.tier, .edited)
        XCTAssertEqual(plan.still.kind, .fullSizePhoto)
        XCTAssertEqual(plan.video.kind, .fullSizePairedVideo)
    }

    func testTiersAreNeverMixedWhateverOrderTheResourcesComeIn() throws {
        let all = Self.originalPair + Self.editedPair
        for permutation in [all, all.reversed(), [all[2], all[1], all[0], all[3]], [all[1], all[3], all[2], all[0]]] {
            let plan = try LivePhotoResourcePlanner.plan(resources: Array(permutation))
            let edited: Set<LivePhotoResourceKind> = [.fullSizePhoto, .fullSizePairedVideo]
            XCTAssertEqual(edited.contains(plan.still.kind), edited.contains(plan.video.kind), "a still and a video from different tiers: \(plan)")
        }
    }

    func testAHalfFinishedEditFallsBackToTheCompleteOriginalPairNotAMix() throws {
        // A full-size still but no full-size video: using it with the original video would pair a
        // cropped still with an uncropped video. The consistent original pair is used instead.
        let resources = Self.originalPair + [Self.resource(.fullSizePhoto, "FullSizeRender.HEIC")]
        let plan = try LivePhotoResourcePlanner.plan(resources: resources)
        XCTAssertEqual(plan.tier, .original)
        XCTAssertEqual(plan.still.kind, .photo)
        XCTAssertEqual(plan.video.kind, .pairedVideo)
    }

    func testAPlainStillIsNotALivePhoto() {
        XCTAssertThrowsError(try LivePhotoResourcePlanner.plan(resources: [Self.resource(.photo, "IMG_0002.HEIC")])) {
            XCTAssertEqual($0 as? LivePhotoStagingError, .notALivePhoto)
            XCTAssertTrue("\($0)".contains("not a Live Photo"))
        }
        XCTAssertThrowsError(try LivePhotoResourcePlanner.plan(resources: [])) {
            XCTAssertEqual($0 as? LivePhotoStagingError, .notALivePhoto)
        }
    }

    func testAMissingStillIsADescriptiveErrorNotAGuess() {
        // A video with nothing to pair it with.
        XCTAssertThrowsError(try LivePhotoResourcePlanner.plan(resources: [Self.resource(.pairedVideo, "IMG_0003.MOV")])) { error in
            guard case .incompleteResources(let detail)? = error as? LivePhotoStagingError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("pairedVideo"), detail)
        }
        // An edited video whose edited still is missing, with no original pair to fall back on.
        XCTAssertThrowsError(try LivePhotoResourcePlanner.plan(resources: [Self.resource(.fullSizePairedVideo, "x.MOV"), Self.resource(.photo, "y.HEIC")]))
    }

    // MARK: - Staging

    func testStagingWritesBothFilesToOneFolderWithTheRightExtensions() async throws {
        let writer = RecordingWriter()
        let staged = try await stager.stage(resources: Self.originalPair) { try await writer.write($0, to: $1, progress: $2) }
        defer { staged.cleanup() }

        XCTAssertEqual(writer.written, [.photo, .pairedVideo], "the still first, then the video")
        XCTAssertEqual(staged.stillURL.deletingLastPathComponent(), staged.directory)
        XCTAssertEqual(staged.videoURL.deletingLastPathComponent(), staged.directory)
        XCTAssertEqual(staged.stillURL.pathExtension, "heic")
        XCTAssertEqual(staged.videoURL.pathExtension, "mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.stillURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.videoURL.path))
        XCTAssertEqual(stager.stagedFolderCount(), 1)
    }

    func testCleanupRemovesTheFolder() async throws {
        let writer = RecordingWriter()
        let staged = try await stager.stage(resources: Self.originalPair) { try await writer.write($0, to: $1, progress: $2) }
        staged.cleanup()
        XCTAssertEqual(stager.stagedFolderCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.directory.path))
    }

    func testAnEditedAssetStagesTheFullSizePairForBothFiles() async throws {
        let writer = RecordingWriter()
        let staged = try await stager.stage(resources: Self.originalPair + Self.editedPair) { try await writer.write($0, to: $1, progress: $2) }
        defer { staged.cleanup() }
        XCTAssertEqual(writer.written, [.fullSizePhoto, .fullSizePairedVideo])
        XCTAssertEqual(staged.plan.tier, .edited)
    }

    // MARK: - Cleanup on error paths

    func testAFailureWritingTheVideoRemovesTheAlreadyWrittenStill() async {
        struct NetworkDown: Error {}
        do {
            _ = try await stager.stage(resources: Self.originalPair) { resource, url, progress in
                try Data("still".utf8).write(to: url)
                if resource.kind == .pairedVideo { throw NetworkDown() }
            }
            XCTFail("expected a failure")
        } catch let error as LivePhotoStagingError {
            guard case .writeFailed(let name, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "video")
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(stager.stagedFolderCount(), 0, "a failed load must leave nothing behind")
    }

    func testAnEmptyFileIsAnErrorAndLeavesNothingBehind() async {
        do {
            _ = try await stager.stage(resources: Self.originalPair) { _, url, _ in
                FileManager.default.createFile(atPath: url.path, contents: Data()) // "succeeds", writes nothing
            }
            XCTFail("expected a failure")
        } catch let error as LivePhotoStagingError {
            XCTAssertEqual(error, .emptyFile(resource: "still"))
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(stager.stagedFolderCount(), 0)
    }

    func testCancellationLeavesNothingBehind() async throws {
        // Captures only Sendable values (not `self`), which Swift 6.3 on CI requires.
        let stager = self.stager!
        let stillWritten = Signal()
        let task = Task {
            try await stager.stage(resources: Self.originalPair) { resource, url, _ in
                try Data("bytes".utf8).write(to: url)
                if resource.kind == .photo { stillWritten.set() }
                try await Task.sleep(for: .seconds(30)) // the video "download" is slow
            }
        }
        for _ in 0..<500 where !stillWritten.isSet { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(stillWritten.isSet, "the still was never written")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(stager.stagedFolderCount(), 0)
    }

    func testNoFolderIsCreatedForAnAssetThatIsNotALivePhoto() async {
        do {
            _ = try await stager.stage(resources: [Self.resource(.photo, "IMG.HEIC")]) { _, _, _ in XCTFail("nothing should be written") }
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? LivePhotoStagingError, .notALivePhoto)
        }
        XCTAssertEqual(stager.stagedFolderCount(), 0)
    }

    func testFoldersFromAnEarlierKilledRunArePurged() throws {
        for _ in 0..<3 {
            let leftover = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: leftover.appendingPathComponent("still.heic"))
        }
        XCTAssertEqual(stager.stagedFolderCount(), 3)
        stager.purgeLeftovers()
        XCTAssertEqual(stager.stagedFolderCount(), 0)
    }

    // MARK: - Progress (the iCloud download path)

    /// What a PhotoKit download looks like: progress arrives in steps while bytes come over the
    /// network, then the file appears.
    func testProgressRunsForwardAcrossBothFilesLikeAnICloudDownload() async throws {
        let seen = LockedArray<Double>()
        let staged = try await stager.stage(
            resources: Self.originalPair,
            writer: { _, url, progress in
                for step in 1...4 {
                    try await Task.sleep(for: .milliseconds(5))
                    progress(Double(step) / 4)
                }
                try Data("downloaded".utf8).write(to: url)
            },
            progress: { seen.append($0) }
        )
        defer { staged.cleanup() }

        let values = seen.values
        XCTAssertEqual(values, values.sorted(), "progress must never go backwards")
        XCTAssertEqual(values.last, 1)
        XCTAssertTrue(values.contains { $0 > 0 && $0 < 0.5 }, "the still's download reports inside the first half: \(values)")
        XCTAssertTrue(values.contains { $0 > 0.5 && $0 < 1 }, "the video's download reports inside the second half: \(values)")
    }

    func testProgressThatStallsOrRestartsDoesNotGoBackwards() async throws {
        let seen = LockedArray<Double>()
        let staged = try await stager.stage(
            resources: Self.originalPair,
            writer: { _, url, progress in
                progress(0.6); progress(0.2); progress(0.9); progress(-3); progress(7) // out of order and out of range
                try Data("ok".utf8).write(to: url)
            },
            progress: { seen.append($0) }
        )
        defer { staged.cleanup() }
        XCTAssertEqual(seen.values, seen.values.sorted())
        XCTAssertTrue(seen.values.allSatisfy { (0...1).contains($0) })
    }

    // MARK: - Extensions

    func testFileExtensionsComeFromTheLibraryNameButStayPlain() {
        XCTAssertEqual(LivePhotoStager.fileExtension(of: Self.resource(.photo, "IMG_1.HEIC"), fallback: "x"), "heic")
        XCTAssertEqual(LivePhotoStager.fileExtension(of: Self.resource(.photo, "noextension"), fallback: "heic"), "heic")
        XCTAssertEqual(LivePhotoStager.fileExtension(of: Self.resource(.photo, "weird.h/e"), fallback: "heic"), "heic")
    }
}

final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    func append(_ value: Element) { lock.withLock { storage.append(value) } }
    var values: [Element] { lock.withLock { storage } }
}

final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
