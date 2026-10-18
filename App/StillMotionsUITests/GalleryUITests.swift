import XCTest

/// UI tests for the gallery, run by hand on a simulator. CI never builds the app.
///
/// They assume the simulator's photo library holds at least 40 Live Photos (some of them distinct)
/// and that photo access is already granted, because a test cannot answer the system prompt:
///
///     xcrun simctl boot <device>
///     xcrun simctl addmedia <device> photo.HEIC photo.MOV        # a Live Photo pair, repeated
///     xcrun simctl privacy <device> grant photos com.began.Still-Motions
///     xcodebuild test -scheme StillMotions -destination 'platform=iOS Simulator,id=<device>'
///
/// With too few photos the tests skip with a message, rather than pass by testing nothing.
@MainActor
final class GalleryUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// `slowThumbnails` holds each thumbnail for a moment (a debug-only launch flag), so scrolling
    /// really does catch requests in flight.
    private func launch(slowThumbnails: Bool = false) {
        app.launchArguments = slowThumbnails ? ["-slowThumbnails"] : []
        app.launch()
    }

    private var cells: XCUIElementQuery {
        app.descendants(matching: .any).matching(identifier: "livePhotoCell")
    }

    /// (started, finished, cancelled, active) read from the debug overlay.
    private func requestCounts() throws -> (started: Int, finished: Int, cancelled: Int, active: Int) {
        let label = app.staticTexts["requestCounts"].label
        let numbers = label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 4 else { throw XCTSkip("could not read the request counts from \"\(label)\"") }
        return (numbers[0], numbers[1], numbers[2], numbers[3])
    }

    private func requireEnoughPhotos() throws {
        XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 15), "the gallery showed no photos; is access granted and the library seeded?")
    }

    func testTappingACellOpensTheEditorForThatPhoto() throws {
        launch()
        try requireEnoughPhotos()
        for index in [0, 1] {
            let cell = cells.element(boundBy: index)
            XCTAssertTrue(cell.waitForExistence(timeout: 5))
            // The cell's label carries its date, and the editor shows the date of the asset it was
            // given, so the two matching means the tap went to the right photo.
            let cellDate = cell.label.replacingOccurrences(of: "Live Photo from ", with: "")
            cell.tap()

            XCTAssertTrue(app.navigationBars["Editor"].waitForExistence(timeout: 5), "tapping cell \(index) did not open the editor")
            let shownDate = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", cellDate)).firstMatch
            XCTAssertTrue(shownDate.waitForExistence(timeout: 5), "the editor does not show the tapped photo's date \(cellDate)")
            app.navigationBars.buttons.firstMatch.tap() // back to the gallery
            XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 5))
        }
    }

    func testScrollingCancelsRequestsForCellsThatLeaveTheScreen() throws {
        launch(slowThumbnails: true)
        try requireEnoughPhotos()
        let before = try requestCounts()

        let scroll = app.scrollViews.firstMatch
        for _ in 0..<8 { scroll.swipeUp(velocity: .fast) }
        for _ in 0..<8 { scroll.swipeDown(velocity: .fast) }
        sleep(4) // longer than the held thumbnail, so everything left has settled

        let after = try requestCounts()
        XCTAssertGreaterThan(after.started, before.started, "scrolling should load new thumbnails")
        XCTAssertGreaterThan(after.cancelled, before.cancelled, "scrolling past cells should cancel their requests: \(before) -> \(after)")
        // Nothing is left running, and nothing is unaccounted for: every request that started
        // either finished or was cancelled.
        XCTAssertEqual(after.active, 0, "requests are still running after scrolling stopped: \(after)")
        XCTAssertEqual(after.started, after.finished + after.cancelled + after.active, "a request was lost: \(after)")
    }

    func testEveryRequestIsAccountedForWithoutScrolling() throws {
        launch()
        try requireEnoughPhotos()
        sleep(2)
        let counts = try requestCounts()
        XCTAssertEqual(counts.started, counts.finished + counts.cancelled + counts.active, "a request was lost: \(counts)")
        XCTAssertEqual(counts.active, 0, "requests are still running at rest: \(counts)")
    }

    /// The numbers in a debug label, in order.
    private func numbers(in identifier: String) -> [Int] {
        app.staticTexts[identifier].label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }

    /// Opens the first photo and waits until the preview is playing.
    private func openFirstPhoto() {
        cells.element(boundBy: 0).tap()
        XCTAssertTrue(app.otherElements["previewImage"].waitForExistence(timeout: 60)
            || app.images["previewImage"].waitForExistence(timeout: 1), "the editor never showed a preview")
    }

    func testSwitchingModeAndRateReplansWithoutReanalyzing() throws {
        launch()
        try requireEnoughPhotos()
        openFirstPhoto()

        // [analyses, plans, memory MB]
        var counters = numbers(in: "editorCounters")
        XCTAssertEqual(counters.first, 1, "the clip should be analyzed exactly once on open")
        let plansAfterOpen = counters[1]

        for mode in ["Bounce", "Once", "Loop"] {
            app.buttons[mode].tap()
        }
        for rate in ["25 fps", "16.7 fps", "20 fps"] {
            app.buttons[rate].tap()
        }
        counters = numbers(in: "editorCounters")
        XCTAssertEqual(counters.first, 1, "switching mode or rate must not re-run the analysis")
        XCTAssertGreaterThan(counters[1], plansAfterOpen, "switching should have rebuilt the playback plan")
        XCTAssertTrue(app.staticTexts["stabilizationStatus"].exists)
    }

    func testSwitchingStabilizationSolvesAgainButNeverEstimatesAgain() throws {
        launch()
        try requireEnoughPhotos()
        openFirstPhoto()

        // [estimates, solves]: the numbers before the word "shown".
        func counts() -> (estimates: Int, solves: Int) {
            let label = app.staticTexts["stabilizationCounters"].label
            let n = label.components(separatedBy: "shown")[0].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return (n[0], n[1])
        }
        XCTAssertEqual(counts().estimates, 1)
        XCTAssertEqual(counts().solves, 1)

        // Each mode shows how much of the frame it keeps, before it is chosen.
        for mode in ["off", "smooth", "locked"] {
            XCTAssertTrue(app.staticTexts["crop-\(mode)"].label.contains("keeps"), "no crop shown for \(mode)")
        }
        XCTAssertEqual(app.staticTexts["crop-off"].label, "keeps 100%")

        var solves = 1
        for mode in ["Smooth", "Off", "Locked"] {
            app.buttons[mode].tap()
            solves += 1
            let shown = app.staticTexts["stabilizationCounters"]
            let settled = NSPredicate(format: "label ENDSWITH %@", "shown \(mode.lowercased())")
            expectation(for: settled, evaluatedWith: shown)
            waitForExpectations(timeout: 60)
            XCTAssertEqual(counts().estimates, 1, "switching to \(mode) estimated motion again")
            XCTAssertEqual(counts().solves, solves, "switching to \(mode) should solve exactly once")
            XCTAssertFalse(app.staticTexts["stabilizationSwitching"].exists)
        }
    }

    func testOpeningAndClosingTheEditorRepeatedlyKeepsMemoryBoundedAndCleansUp() throws {
        launch()
        try requireEnoughPhotos()
        var memory: [Int] = []
        for _ in 0..<5 {
            openFirstPhoto()
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(cells.firstMatch.waitForExistence(timeout: 5))
            // [staged folders, memory MB]
            let counts = numbers(in: "stagingCounts")
            XCTAssertEqual(counts.first, 0, "extracted files were left behind after closing the editor")
            memory.append(counts[1])
        }
        print("MEMORY AFTER EACH CLOSE (MB): \(memory)")
        // Simulator memory is not the phone's; this only catches a cache that is never released.
        XCTAssertLessThan(memory.last! - memory.first!, 150, "memory kept growing across opens: \(memory)")
    }
}
