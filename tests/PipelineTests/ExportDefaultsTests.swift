import XCTest
@testable import StillMotionsPipeline

final class ExportDefaultsTests: XCTestCase {
    var suiteName: String!
    var suite: UserDefaults!

    override func setUp() {
        suiteName = "exportdefaults-test-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        suite.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsMatchThePRDExactly() {
        // PRD §1.1: Medium, 20 fps, Loop, GIF. Each is pinned so changing one is a deliberate edit.
        let defaults = ExportDefaultsStore(defaults: suite).load()
        XCTAssertEqual(defaults.sizePreset, .medium)
        XCTAssertEqual(defaults.sizePreset.longEdge, 720)
        XCTAssertEqual(defaults.gifFrameRate, .fps20)
        XCTAssertEqual(defaults.gifFrameRate.centiseconds, 5, "20 fps is exactly 5 centiseconds")
        XCTAssertEqual(defaults.mode, .loop)
        XCTAssertEqual(defaults.format, .gif)
        XCTAssertEqual(defaults, ExportDefaults())
    }

    func testChoicesPersistAcrossARelaunch() {
        var chosen = ExportDefaults()
        chosen.sizePreset = .full
        chosen.gifFrameRate = .fps25
        chosen.mode = .bounce
        chosen.format = .mp4
        ExportDefaultsStore(defaults: suite).save(chosen)

        // A relaunch is a new store object over the same defaults.
        let afterRelaunch = ExportDefaultsStore(defaults: suite).load()
        XCTAssertEqual(afterRelaunch, chosen)
    }

    func testEveryCaseOfEveryChoiceRoundTrips() {
        let store = ExportDefaultsStore(defaults: suite)
        for preset in SizePreset.allCases {
            for rate in GifFrameRate.allCases {
                for mode in PlaybackMode.allCases {
                    for format in ExportFormat.allCases {
                        var values = ExportDefaults()
                        (values.sizePreset, values.gifFrameRate, values.mode, values.format) = (preset, rate, mode, format)
                        store.save(values)
                        XCTAssertEqual(store.load(), values)
                    }
                }
            }
        }
    }

    func testAnUnrecognizedStoredValueFallsBackAloneAndLeavesTheOthers() {
        // An older or newer build wrote a value this one does not know. Only that field resets.
        suite.set("full", forKey: "exportDefaults.sizePreset")
        suite.set("ultra-hd", forKey: "exportDefaults.gifFrameRate") // not a case
        suite.set("bounce", forKey: "exportDefaults.mode")
        suite.set("webp", forKey: "exportDefaults.format") // not a case

        let loaded = ExportDefaultsStore(defaults: suite).load()
        XCTAssertEqual(loaded.sizePreset, .full)
        XCTAssertEqual(loaded.gifFrameRate, .fps20, "unknown value falls back to the default")
        XCTAssertEqual(loaded.mode, .bounce)
        XCTAssertEqual(loaded.format, .gif, "unknown value falls back to the default")
    }

    func testResetReturnsToThePRDDefaults() {
        let store = ExportDefaultsStore(defaults: suite)
        var changed = ExportDefaults()
        changed.mode = .once
        changed.sizePreset = .small
        store.save(changed)
        XCTAssertNotEqual(store.load(), ExportDefaults())
        store.reset()
        XCTAssertEqual(store.load(), ExportDefaults())
    }

    func testStoresWithDifferentPrefixesDoNotShareState() {
        var a = ExportDefaults(); a.mode = .once
        ExportDefaultsStore(defaults: suite, prefix: "a.").save(a)
        XCTAssertEqual(ExportDefaultsStore(defaults: suite, prefix: "b.").load(), ExportDefaults())
    }
}
