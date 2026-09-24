import XCTest

// Placeholder so the test target compiles and `swift test` is meaningful from the first
// commit. Real tests arrive with the modules they cover.
//
// XCTest rather than swift-testing: on macOS both require a full Xcode install, so
// swift-testing buys no portability here, and XCTest is the more familiar of the two for a
// developer who reads Swift without specialising in it. Switching to `import Testing` later
// is a mechanical change if preferred.
//
// NOTE FOR THE BUILD AGENT: this file was written on a planning machine with Command Line
// Tools only, where neither XCTest nor Testing resolves. `swift build` was verified there;
// `swift test` was NOT. Confirm it runs on the build machine as part of the package
// skeleton issue.
//
// Test plan, per PRD:
//   R-4   importer frame count and reference index, per synthetic fixture
//   R-5   recovered transforms vs each fixture's known motion path
//   R-6   transform error lower with masking enabled on the moving-foreground fixture
//   R-7   computed crop matches the analytically-derived rectangle within 1 px
//   R-8   selected loop length within one frame of a periodic fixture's known period
//   R-11  every fixture yields a playable GIF and MP4; GIF loops infinitely in Loop mode
//
// This target lives at tests/PipelineTests with an explicit `path:` in Package.swift.
// Do not create a `Tests/` directory — macOS APFS is case-insensitive, so it would be the
// same directory as tests/fixtures and produce baffling build errors.
// See docs/ARCHITECTURE.md §8.
final class PlaceholderTests: XCTestCase {
    func testTargetCompiles() {
        XCTAssertTrue(true)
    }
}
