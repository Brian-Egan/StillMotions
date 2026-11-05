import XCTest
@testable import StillMotionsPipeline

/// #36: the share extension's drop box and its manifest. These are the guarantees the extension and the
/// app (#37) both rely on, so they are tested here, not by hand in a share sheet.
final class DropBoxTests: XCTestCase {
    var root: URL!
    var sources: URL!
    var dropBox: DropBox!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("dropbox-test-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("DropBox", isDirectory: true)
        sources = base.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        dropBox = DropBox(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    /// A file with `size` bytes, standing in for what the system hands the extension.
    func source(_ name: String, size: Int = 4096) throws -> URL {
        let url = sources.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: size).write(to: url)
        return url
    }

    @discardableResult
    func share(still: String = "IMG_0001.HEIC", video: String = "IMG_0001.MOV", now: Date = Date()) throws -> DropBox.Manifest {
        let staging = try dropBox.begin()
        let stillName = try staging.copy(try source(still), as: .still)
        let videoName = try staging.copy(try source(video), as: .video)
        return try staging.finish(stillFile: stillName, videoFile: videoName, now: now)
    }

    // MARK: - Staging

    func testAShareStagesBothFilesAndAManifest() throws {
        let manifest = try share()
        XCTAssertEqual(manifest.version, DropBox.Manifest.currentVersion)
        XCTAssertEqual(manifest.stillFile, "still.heic")
        XCTAssertEqual(manifest.videoFile, "video.mov")
        let folder = dropBox.folder(for: manifest.id)
        for name in [manifest.stillFile, manifest.videoFile, DropBox.manifestFileName] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was not staged")
        }
        XCTAssertEqual(try Data(contentsOf: dropBox.stillURL(of: manifest)).count, 4096, "the file is copied whole")
        XCTAssertEqual(dropBox.finishedShares(), [manifest])
        XCTAssertTrue(dropBox.unfinishedFolders().isEmpty)
    }

    func testThreeSharesInARowDoNotCollide() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let manifests = try (0..<3).map { try share(now: start.addingTimeInterval(Double($0))) }
        XCTAssertEqual(Set(manifests.map(\.id)).count, 3, "each share gets its own identity")
        XCTAssertEqual(Set(manifests.map { dropBox.folder(for: $0.id) }).count, 3, "and its own folder")
        XCTAssertEqual(dropBox.finishedShares(), manifests, "all three are there, oldest first")
    }

    func testTheSameSourceSharedTwiceIsTwoSharesNotACrash() throws {
        let first = try share(still: "same.HEIC", video: "same.MOV")
        let second = try share(still: "same.HEIC", video: "same.MOV")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(dropBox.finishedShares().count, 2)
    }

    func testTheManifestIsWrittenLastSoAShareKilledHalfWayIsNotFinished() throws {
        let staging = try dropBox.begin()
        _ = try staging.copy(try source("a.HEIC"), as: .still)
        // Killed here: the still is staged, the video and the manifest are not.
        XCTAssertTrue(dropBox.finishedShares().isEmpty, "no manifest means not a finished share")
        // Compared by name: the same temp folder can be spelled /var/... or /private/var/... on macOS.
        XCTAssertEqual(dropBox.unfinishedFolders().map(\.lastPathComponent), [staging.id.uuidString], "it is found, so the app can clear it")
    }

    func testAbortRemovesEverythingTheShareWrote() throws {
        let staging = try dropBox.begin()
        _ = try staging.copy(try source("a.HEIC"), as: .still)
        staging.abort()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.folder.path))
        XCTAssertTrue(dropBox.unfinishedFolders().isEmpty)
    }

    func testAnEmptyFileIsRefusedNotStaged() throws {
        let staging = try dropBox.begin()
        XCTAssertThrowsError(try staging.copy(try source("empty.HEIC", size: 0), as: .still)) { error in
            guard case DropBoxError.emptyFile = error else { return XCTFail("\(error)") }
        }
    }

    func testAFileThatIsNotThereIsAClearError() throws {
        let staging = try dropBox.begin()
        XCTAssertThrowsError(try staging.copy(sources.appendingPathComponent("gone.HEIC"), as: .still)) { error in
            guard case DropBoxError.cannotWrite = error else { return XCTFail("\(error)") }
        }
    }

    func testFileExtensionsAreKeptAndMadeSafe() throws {
        let staging = try dropBox.begin()
        XCTAssertEqual(try staging.copy(try source("a.HEIC"), as: .still), "still.heic")
        XCTAssertEqual(try staging.copy(try source("b.JPG"), as: .still), "still.jpg")
        XCTAssertEqual(try staging.copy(try source("c.mov"), as: .video), "video.mov")
        XCTAssertEqual(try staging.copy(try source("noextension"), as: .video), "video")
        XCTAssertEqual(try staging.copy(try source("odd.he!i?c"), as: .still), "still.heic", "odd characters in an extension are stripped")
    }

    // MARK: - Reading what was staged (for the app's drain, #37)

    func testAManifestThatCannotBeTrustedIsNotAFinishedShare() throws {
        let good = try share()
        let corrupt = try share()
        let unknownVersion = try share()
        let missingFile = try share()
        let wrongFolder = try share()

        try Data("{not json".utf8).write(to: dropBox.folder(for: corrupt.id).appendingPathComponent(DropBox.manifestFileName))
        var future = unknownVersion; future.version = 99
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(future).write(to: dropBox.folder(for: unknownVersion.id).appendingPathComponent(DropBox.manifestFileName))
        try FileManager.default.removeItem(at: dropBox.videoURL(of: missingFile))
        // A manifest copied into a folder that is not its own.
        try encoder.encode(good).write(to: dropBox.folder(for: wrongFolder.id).appendingPathComponent(DropBox.manifestFileName))

        XCTAssertEqual(dropBox.finishedShares(), [good])
        XCTAssertEqual(Set(dropBox.unfinishedFolders().map(\.lastPathComponent)),
                       Set([corrupt, unknownVersion, missingFile, wrongFolder].map(\.id.uuidString)),
                       "everything that cannot be trusted is reported, to be cleared with its files")
    }

    func testRemovingAShareRemovesItsFiles() throws {
        let manifest = try share()
        dropBox.remove(manifest.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropBox.folder(for: manifest.id).path))
        XCTAssertTrue(dropBox.finishedShares().isEmpty)
    }

    func testAnEmptyOrMissingDropBoxHasNothingInIt() {
        XCTAssertTrue(dropBox.finishedShares().isEmpty)
        XCTAssertTrue(dropBox.unfinishedFolders().isEmpty)
    }

    func testTheManifestSurvivesBeingWrittenAndRead() throws {
        let when = Date(timeIntervalSince1970: 1_800_000_123.75)  // a time with a fraction of a second
        let manifest = try share(now: when)
        let read = try XCTUnwrap(dropBox.finishedShares().first)
        XCTAssertEqual(read, manifest)
        XCTAssertEqual(read.createdAt.timeIntervalSince1970, 1_800_000_123, "the time is kept to the whole second, as the manifest stores it")
    }

    // MARK: - What the person reads

    func testTheConfirmationTellsThemToOpenTheApp() {
        // The extension cannot open the app, so without this sentence the share looks like it did nothing.
        XCTAssertTrue(DropBox.confirmationMessage.contains("Open StillMotions"), DropBox.confirmationMessage)
    }

    func testEveryFailureHasAMessageSayingWhatToDo() {
        let errors: [DropBoxError] = [.noContainer, .notALivePhoto, .timedOut, .cannotWrite("x"), .emptyFile("x"), .nothingShared]
        for error in errors {
            XCTAssertGreaterThan(error.userMessage.count, 20, "\(error)")
            XCTAssertFalse(error.userMessage.contains("Error"), "plain words, not an error code: \(error.userMessage)")
        }
        XCTAssertTrue(DropBoxError.notALivePhoto.userMessage.contains("Live Photo"))
        XCTAssertTrue(DropBoxError.timedOut.userMessage.contains("iCloud"))
    }
}

/// #36: which pieces of a share to copy.
final class ShareSourceTests: XCTestCase {
    func testALivePhotoBundleIsCopiedOutOfItsFolder() {
        let plan = ShareSource.plan(attachments: [["com.apple.live-photo-bundle", "public.heic"]])
        XCTAssertEqual(plan, .bundle(attachment: 0, typeIdentifier: "com.apple.live-photo-bundle"))
    }

    func testAStillAndAMovieOfferedSeparatelyArePaired() {
        let plan = ShareSource.plan(attachments: [["public.heic", "public.jpeg"], ["com.apple.quicktime-movie"]])
        XCTAssertEqual(plan, .pair(
            still: ShareSource.Pick(attachment: 0, typeIdentifier: "public.heic"),
            video: ShareSource.Pick(attachment: 1, typeIdentifier: "com.apple.quicktime-movie")
        ))
    }

    func testTheOrderTheyAreOfferedInDoesNotMatter() {
        let plan = ShareSource.plan(attachments: [["com.apple.quicktime-movie"], ["public.heic"]])
        XCTAssertEqual(plan, .pair(
            still: ShareSource.Pick(attachment: 1, typeIdentifier: "public.heic"),
            video: ShareSource.Pick(attachment: 0, typeIdentifier: "com.apple.quicktime-movie")
        ))
    }

    func testHeicIsPreferredToJpegForTheStill() {
        let plan = ShareSource.plan(attachments: [["public.jpeg", "public.heic"], ["public.mpeg-4"]])
        guard case .pair(let still, let video) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(still.typeIdentifier, "public.heic")
        XCTAssertEqual(video.typeIdentifier, "public.mpeg-4", "any movie type counts")
    }

    func testARegularPhotoIsNotALivePhoto() {
        XCTAssertEqual(ShareSource.plan(attachments: [["public.heic", "public.jpeg"]]), .notALivePhoto)
        XCTAssertEqual(ShareSource.plan(attachments: [["public.jpeg"]]), .notALivePhoto)
    }

    func testAMovieAloneIsNotALivePhoto() {
        XCTAssertEqual(ShareSource.plan(attachments: [["com.apple.quicktime-movie"]]), .notALivePhoto)
    }

    func testNothingOrUnknownTypesIsNotALivePhoto() {
        XCTAssertEqual(ShareSource.plan(attachments: []), .notALivePhoto)
        XCTAssertEqual(ShareSource.plan(attachments: [["public.plain-text"], ["public.url"]]), .notALivePhoto)
    }

    func testThePiecesOfABundleAreFoundByWhatTheyAre() {
        let urls = ["/b/IMG_0042.MOV", "/b/IMG_0042.HEIC", "/b/Info.plist"].map { URL(fileURLWithPath: $0) }
        let pair = ShareSource.stillAndVideo(in: urls)
        XCTAssertEqual(pair?.still.lastPathComponent, "IMG_0042.HEIC")
        XCTAssertEqual(pair?.video.lastPathComponent, "IMG_0042.MOV")
        XCTAssertNil(ShareSource.stillAndVideo(in: [URL(fileURLWithPath: "/b/IMG.HEIC")]), "a bundle with no movie is not usable")
        XCTAssertNil(ShareSource.stillAndVideo(in: []))
    }
}
