import XCTest
@testable import StillMotionsPipeline

/// #34: the editable pixel sizes of Small and Medium.
final class PresetSizesTests: XCTestCase {
    var suiteName: String!
    var suite: UserDefaults!

    override func setUp() {
        suiteName = "presetsizes-test-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
    }
    override func tearDown() { suite.removePersistentDomain(forName: suiteName) }

    func testTheStandardSizesAreThePRDsAndFullIsNative() {
        let sizes = PresetSizes.standard
        XCTAssertEqual(sizes.longEdge(for: .small), 480)
        XCTAssertEqual(sizes.longEdge(for: .medium), 720)
        XCTAssertNil(sizes.longEdge(for: .full), "Full is native by definition")
        XCTAssertEqual(SizePreset.small.longEdge, 480)
        XCTAssertEqual(SizePreset.medium.longEdge, 720)
    }

    func testAValueInRangeIsAccepted() {
        var sizes = PresetSizes.standard
        XCTAssertEqual(sizes.setSmall(600), .accepted)
        XCTAssertEqual(sizes.setMedium(1080), .accepted)
        XCTAssertEqual(sizes, PresetSizes(small: 600, medium: 1080))
    }

    func testAValueOutsideTheBoundsIsClampedWithAReason() {
        var sizes = PresetSizes.standard
        guard case .adjusted(let low, let lowReason) = sizes.setSmall(50) else { return XCTFail("50 px should be refused") }
        XCTAssertEqual(low, 240)
        XCTAssertTrue(lowReason.contains("240"), lowReason)
        guard case .adjusted(let high, let highReason) = sizes.setMedium(9999) else { return XCTFail("9999 px should be refused") }
        XCTAssertEqual(high, 1920)
        XCTAssertTrue(highReason.contains("1920"), highReason)
        XCTAssertEqual(sizes, PresetSizes(small: 240, medium: 1920))
    }

    func testSmallStaysBelowMediumAndMediumAboveSmall() {
        var sizes = PresetSizes(small: 480, medium: 720)
        guard case .adjusted(let small, let reason) = sizes.setSmall(900) else { return XCTFail("Small above Medium should be adjusted") }
        XCTAssertEqual(small, 710)
        XCTAssertTrue(reason.contains("Medium"), reason)
        XCTAssertLessThan(sizes.small, sizes.medium)

        sizes = PresetSizes(small: 480, medium: 720)
        guard case .adjusted(let medium, _) = sizes.setMedium(300) else { return XCTFail("Medium below Small should be adjusted") }
        XCTAssertEqual(medium, 490)
        XCTAssertLessThan(sizes.small, sizes.medium)
    }

    func testEditedSizesChangeTheOutputDimensionsAndTheEstimate() {
        let path = ExportSizingTests.path
        let times = ExportSizingTests.frameTimes
        func size(_ sizes: PresetSizes) -> (Int, Int) {
            let input = ExportSizing.input(format: .gif, preset: .small, sizes: sizes, mode: .once, gifRate: .fps20, path: path, frameTimes: times, loop: nil, sourceFrameRate: 30, content: nil)
            return (input.width, input.height)
        }
        XCTAssertEqual(size(.standard).0, 480)
        XCTAssertEqual(size(PresetSizes(small: 600, medium: 720)).0, 600)
        func estimate(_ sizes: PresetSizes) -> Int {
            ExportSizing.estimate(format: .gif, preset: .small, sizes: sizes, mode: .once, gifRate: .fps20, path: path, frameTimes: times, loop: nil, sourceFrameRate: 30, content: nil)
        }
        XCTAssertLessThan(estimate(.standard), estimate(PresetSizes(small: 600, medium: 720)), "a larger Small must cost more")
    }

    func testTheSizesPersistAndResetToThePRDValues() {
        let store = ExportDefaultsStore(defaults: suite)
        var chosen = ExportDefaults()
        chosen.presetSizes = PresetSizes(small: 400, medium: 1000)
        store.save(chosen)
        XCTAssertEqual(ExportDefaultsStore(defaults: suite).load().presetSizes, PresetSizes(small: 400, medium: 1000))
        store.reset()
        XCTAssertEqual(store.load(), ExportDefaults(), "reset restores exactly the PRD values")
        XCTAssertEqual(store.load().presetSizes, .standard)
    }

    func testBadStoredSizesFallBackToTheStandardOnes() {
        for (small, medium) in [(10, 720), (480, 5000), (800, 700), (500, 500)] {
            suite.set(small, forKey: "exportDefaults.smallLongEdge")
            suite.set(medium, forKey: "exportDefaults.mediumLongEdge")
            XCTAssertEqual(ExportDefaultsStore(defaults: suite).load().presetSizes, .standard, "\(small)/\(medium) should not be trusted")
        }
        // Another stored choice is untouched by a bad size.
        suite.set("full", forKey: "exportDefaults.sizePreset")
        XCTAssertEqual(ExportDefaultsStore(defaults: suite).load().sizePreset, .full)
    }
}
