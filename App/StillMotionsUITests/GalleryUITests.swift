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
        let shown = app.otherElements["previewImage"].waitForExistence(timeout: 90) || app.images["previewImage"].waitForExistence(timeout: 1)
        if !shown {
            // Say what the screen showed instead, so a failure here can be told from a slow simulator.
            let texts = app.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label).joined(separator: " | ")
            XCTFail("the editor never showed a preview. On screen: \(texts). Navigation bar: \(app.navigationBars.firstMatch.identifier)")
        }
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

        // A clip where Locked would keep under 60% of the frame starts in Smooth (#98), so do not assume
        // which one is showing. Walk the three in an order where every tap changes the stabilization.
        let startedIn = app.staticTexts["stabilizationCounters"].label.components(separatedBy: "shown ").last ?? ""
        let cycle = ["Smooth", "Off", "Locked"]
        let first = cycle.firstIndex { $0.lowercased() != startedIn } ?? 0
        var solves = 1
        for step in 0..<3 {
            let mode = cycle[(first + step) % 3]
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

    /// Turns a switch to `wanted` by tapping its own control (the right-hand end of its row; the middle is
    /// the label, which does not toggle it), waiting for the screen to stop moving first. A tap can still be
    /// missed on a busy simulator, so it looks at the switch's value and taps again, and reports how many
    /// taps it took: if that is usually more than one, the app has a problem, not the test.
    @discardableResult
    private func setSwitch(_ toggle: XCUIElement, to wanted: Bool) -> Int {
        var last = toggle.frame
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            let now = toggle.frame
            if now == last, toggle.isHittable { break }
            last = now
        }
        let wantedValue = wanted ? "1" : "0"
        for attempt in 1...4 {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            // The value flips at once when the tap lands, whatever work follows, so poll it for a few seconds.
            for _ in 0..<12 {
                if (toggle.value as? String) == wantedValue { return attempt }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        XCTFail("the switch never turned \(wanted ? "on" : "off") after 4 taps")
        return 4
    }

    func testIgnoringPeopleEstimatesOnceAndNothingElseDoes() throws {
        launch()
        try requireEnoughPhotos()
        openFirstPhoto()

        func counts() -> (estimates: Int, solves: Int, shown: String) {
            let label = app.staticTexts["stabilizationCounters"].label
            let n = label.components(separatedBy: "shown")[0].split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            return (n[0], n[1], label.components(separatedBy: "shown ").last ?? "")
        }
        func waitForPeople(_ state: String) {
            let settled = NSPredicate(format: "label ENDSWITH %@", state)
            expectation(for: settled, evaluatedWith: app.staticTexts["peopleCounters"])
            waitForExpectations(timeout: 180)
        }
        XCTAssertEqual(app.staticTexts["peopleCounters"].label, "people ignored: no", "it starts off")
        XCTAssertEqual(counts().estimates, 1)
        XCTAssertEqual(counts().solves, 1)

        // On: one new estimate and one new solve. Tap the switch itself (the right-hand end of the row):
        // the middle of a switch row is its label, which does not toggle it.
        let toggle = app.switches["ignorePeopleToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        setSwitch(toggle, to: true)
        let started = app.staticTexts["stabilizationWorking"].waitForExistence(timeout: 15)
        XCTAssertTrue(started || app.staticTexts["peopleCounters"].label.hasSuffix("yes"),
                      "the tap did not turn the switch on (value: \(String(describing: toggle.value)); problem: \(app.staticTexts["ignorePeopleProblem"].exists ? app.staticTexts["ignorePeopleProblem"].label : "none"))")
        waitForPeople("yes")
        XCTAssertEqual(counts().estimates, 2, "turning it on estimates the motion once more, with people masked")
        XCTAssertEqual(counts().solves, 2)
        XCTAssertFalse(app.staticTexts["stabilizationWorking"].exists, "the working note goes away when it is done")
        XCTAssertFalse(app.staticTexts["ignorePeopleProblem"].exists)

        // Changing the stabilization still never estimates.
        let other = ["Smooth", "Off", "Locked"].first { $0.lowercased() != counts().shown }!
        app.buttons[other].tap()
        let switched = NSPredicate(format: "label ENDSWITH %@", "shown \(other.lowercased())")
        expectation(for: switched, evaluatedWith: app.staticTexts["stabilizationCounters"])
        waitForExpectations(timeout: 60)
        XCTAssertEqual(counts().estimates, 2, "a mode switch must not estimate")
        XCTAssertEqual(counts().solves, 3)

        // Off again: the first estimate is used again, so nothing is estimated.
        setSwitch(app.switches["ignorePeopleToggle"], to: false)
        waitForPeople("no")
        XCTAssertEqual(counts().estimates, 2, "turning it off re-uses the first estimate")
        XCTAssertEqual(counts().solves, 4)
        XCTAssertEqual(counts().shown, other.lowercased(), "and the stabilization the user chose is kept")

        // On once more: the saved masked estimate is re-used.
        setSwitch(app.switches["ignorePeopleToggle"], to: true)
        waitForPeople("yes")
        XCTAssertEqual(counts().estimates, 2, "the masked estimate is kept, so turning it on again is free")
        XCTAssertEqual(counts().solves, 5)
    }

    /// "about 1.2 MB" or "850 KB" as bytes.
    private func bytes(in text: String) -> Double? {
        guard let match = text.range(of: #"([0-9]+(?:[.,][0-9]+)?)\s*(bytes|KB|MB|GB)"#, options: .regularExpression) else { return nil }
        let parts = text[match].split(separator: " ")
        guard parts.count >= 2, let value = Double(parts[0].replacingOccurrences(of: ",", with: ".")) else { return nil }
        let unit: [String: Double] = ["bytes": 1, "KB": 1_000, "MB": 1_000_000, "GB": 1_000_000_000]
        return value * (unit[String(parts[1])] ?? 1)
    }

    func testExportChoicesFollowTheFormatRulesAndShowAnEstimateForEachPreset() throws {
        launch()
        try requireEnoughPhotos()
        openFirstPhoto()
        let gif = app.buttons["format-gif"], mp4 = app.buttons["format-mp4"]
        XCTAssertTrue(gif.waitForExistence(timeout: 10))

        // Loop is the default mode: GIF is chosen, MP4 is unavailable, and the reason is on screen.
        XCTAssertTrue(gif.isSelected, "GIF should be selected")
        XCTAssertFalse(mp4.isEnabled, "MP4 can't loop")
        XCTAssertTrue(app.staticTexts["formatReason"].exists, "a disabled MP4 needs a visible reason")
        XCTAssertTrue(app.staticTexts["formatReason"].label.contains("GIF"))

        // Bounce and Once offer both formats.
        for mode in ["Bounce", "Once"] {
            app.buttons[mode].tap()
            XCTAssertTrue(mp4.isEnabled, "\(mode) should allow MP4")
            XCTAssertFalse(app.staticTexts["formatReason"].exists, "no reason once nothing is disabled")
        }
        mp4.tap()
        XCTAssertTrue(mp4.isSelected)
        XCTAssertTrue(app.staticTexts["rateNote"].exists, "MP4 keeps the clip's own rate, and the screen should say so")

        // Choosing Loop while MP4 is selected moves to GIF rather than leaving an impossible choice.
        app.buttons["Loop"].tap()
        XCTAssertTrue(gif.isSelected)
        XCTAssertFalse(mp4.isEnabled)

        // Each preset shows an estimate, and they are in order: that is the choice they are for.
        let sizes = ["preset-small", "preset-medium", "preset-full"].map { bytes(in: app.buttons[$0].label) }
        XCTAssertFalse(sizes.contains { $0 == nil }, "every preset should show an estimate: \(sizes)")
        let small = sizes[0]!, medium = sizes[1]!, full = sizes[2]!
        XCTAssertLessThan(small, medium)
        XCTAssertLessThan(medium, full)

        // The estimate for the chosen preset is shown, and a higher GIF frame rate raises it.
        app.buttons["preset-medium"].tap()
        app.segmentedControls["ratePicker"].buttons["16.7 fps"].tap()
        let slow = try XCTUnwrap(bytes(in: app.staticTexts["estimatedSize"].label))
        app.segmentedControls["ratePicker"].buttons["25 fps"].tap()
        let fast = try XCTUnwrap(bytes(in: app.staticTexts["estimatedSize"].label))
        XCTAssertGreaterThan(fast, slow, "more frames per second should cost more bytes")

        // Only the three frame rates whose delay is a whole number of centiseconds are offered.
        XCTAssertEqual(app.segmentedControls["ratePicker"].buttons.count, 3)
    }

    /// "export folders on disk: N" as N.
    private func exportFolders() -> Int? {
        Int(app.staticTexts["exportFolders"].label.split(whereSeparator: { !$0.isNumber }).last ?? "")
    }

    func testSavingToPhotosCompletesAndLeavesNoFilesBehind() throws {
        launch()
        try requireEnoughPhotos()
        // If the system asks for permission to add to Photos, allow it.
        addUIInterruptionMonitor(withDescription: "Photos permission") { alert in
            for label in ["Allow Full Access", "Allow", "OK"] where alert.buttons[label].exists { alert.buttons[label].tap(); return true }
            return false
        }
        openFirstPhoto()
        XCTAssertEqual(exportFolders(), 0, "nothing should be on disk before an export")

        app.buttons["exportSave"].tap()
        app.tap() // lets the interruption monitor see an alert, if there is one
        let status = app.staticTexts["exportStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 120), "the export never finished")
        XCTAssertTrue(status.label.contains("Saved"), status.label)
        XCTAssertEqual(exportFolders(), 0, "the temporary file must be removed once it is saved")
    }

    func testCancellingAnExportStopsItAndLeavesNothingBehind() throws {
        launch()
        try requireEnoughPhotos()
        openFirstPhoto()
        app.buttons["preset-full"].tap() // the slowest, so there is time to cancel

        app.buttons["exportShare"].tap()
        let cancel = app.buttons["exportCancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "progress and Cancel should appear while exporting")
        XCTAssertTrue(app.progressIndicators["exportProgress"].exists || app.otherElements["exportProgress"].exists, "export shows a determinate progress bar")
        cancel.tap()

        XCTAssertTrue(app.buttons["exportShare"].waitForExistence(timeout: 30), "the export controls should come back after Cancel")
        XCTAssertFalse(app.sheets.firstMatch.exists, "a cancelled export must not open the share sheet")
        // The controls come back at once; the job removes its folder a moment later, when the encoder
        // notices the cancellation. The debug readout only redraws when something changes, so poke
        // a harmless control between looks.
        var folders = exportFolders()
        for _ in 0..<20 where folders != 0 {
            sleep(1)
            app.buttons["preset-small"].tap()
            folders = exportFolders()
        }
        XCTAssertEqual(folders, 0, "a cancelled export must leave no folder behind")
    }

    /// Replaces the text of a settings size field and submits it.
    private func typeSize(_ value: String, into id: String) {
        let field = app.textFields[id]
        // Tap at the right-hand end: the text is right-aligned, so that puts the cursor after it and
        // the deletes below remove it. A tap in the middle leaves the cursor mid-number.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6))
        field.typeText(value + "\n")
    }

    func testSettingsKeepSizesWithinBoundsPersistAndChangeWhatTheEditorOffers() throws {
        launch()
        try requireEnoughPhotos()
        app.buttons["openSettings"].tap()
        XCTAssertTrue(app.textFields["settingsSmall"].waitForExistence(timeout: 5))
        // The simulator keeps settings between runs, so start from the shipped values.
        app.buttons["settingsReset"].tap()
        XCTAssertEqual(app.textFields["settingsSmall"].value as? String, "480")
        XCTAssertEqual(app.textFields["settingsMedium"].value as? String, "720")

        // Out of bounds: changed, with the reason on screen.
        typeSize("50", into: "settingsSmall")
        XCTAssertTrue(app.staticTexts["settingsSizeNote"].waitForExistence(timeout: 5), "an out-of-range size needs an explanation")
        XCTAssertTrue(app.staticTexts["settingsSizeNote"].label.contains("240"), "note was: \(app.staticTexts["settingsSizeNote"].label) | field: \(app.textFields["settingsSmall"].value as? String ?? "nil")")
        XCTAssertEqual(app.textFields["settingsSmall"].value as? String, "240")

        // In bounds: accepted, no note.
        typeSize("600", into: "settingsSmall")
        XCTAssertEqual(app.textFields["settingsSmall"].value as? String, "600")
        XCTAssertFalse(app.staticTexts["settingsSizeNote"].exists)

        // Survives a relaunch.
        app.terminate()
        launch()
        try requireEnoughPhotos()
        app.buttons["openSettings"].tap()
        XCTAssertEqual(app.textFields["settingsSmall"].value as? String, "600", "the size should persist across launches")
        app.navigationBars.buttons.firstMatch.tap()

        // The editor offers the edited size.
        openFirstPhoto()
        XCTAssertTrue(app.buttons["preset-small"].label.contains("Small 600"), app.buttons["preset-small"].label)
        app.navigationBars.buttons.firstMatch.tap()

        // Reset restores exactly the shipped values.
        app.buttons["openSettings"].tap()
        app.buttons["settingsReset"].tap()
        XCTAssertEqual(app.textFields["settingsSmall"].value as? String, "480")
        XCTAssertEqual(app.textFields["settingsMedium"].value as? String, "720")
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
