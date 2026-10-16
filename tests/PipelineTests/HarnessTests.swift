import XCTest
@testable import HarnessCLI
@testable import StillMotionsPipeline

final class HarnessTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("harness-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func touch(_ relative: String, contents: String = "") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - Discovery

    func testFindsClipsFlatAndOneFolderPerPhoto() throws {
        try touch("flat.mov")
        try touch("zeta/IMG_2.MOV")
        try touch("zeta/IMG_2.HEIC")
        try touch("alpha/IMG_1.mov")
        try touch("alpha/IMG_1.heic")
        try touch("alpha/IMG_1.AAE") // a library export's sidecar, ignored
        try touch("notes.txt")

        // A symlinked folder (how a few photos are pointed at without copying them).
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("harness-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: elsewhere) }
        try Data().write(to: elsewhere.appendingPathComponent("LINKED.MOV"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: elsewhere)

        let clips = try ClipLocator.find(in: root)
        XCTAssertEqual(clips.map(\.name), ["IMG_1", "IMG_2", "LINKED", "flat"], "sorted by name")
        XCTAssertNotNil(clips.first { $0.name == "IMG_1" }?.stillURL, "a still next to the movie is found, whatever its case")
        XCTAssertNotNil(clips.first { $0.name == "IMG_2" }?.stillURL)
        XCTAssertNil(clips.first { $0.name == "flat" }?.stillURL)
        XCTAssertEqual(clips.first { $0.name == "LINKED" }?.movieURL.lastPathComponent, "LINKED.MOV")
    }

    // MARK: - Unprocessable clips

    func testAClipThatCannotBeProcessedIsRecordedAndTheRunContinues() async throws {
        // Two movies that are not movies. Each fails to decode; neither may stop the other, and
        // both must appear in the results as failures with a reason.
        try touch("a/BAD_A.mov", contents: "not a movie")
        try touch("b/BAD_B.mov", contents: "also not a movie")
        let out = root.appendingPathComponent("out")

        let exit = try await HarnessRunner.run(arguments: ["--fixtures", root.path, "--out", out.path])
        XCTAssertEqual(exit, 0, "no baseline was given, so there is nothing to regress against")

        let data = try Data(contentsOf: out.appendingPathComponent("summary.json"))
        let summary = try JSONDecoder().decode(HarnessRunner.Summary.self, from: data)
        XCTAssertEqual(summary.clipCount, 2)
        XCTAssertEqual(summary.passedCount, 0)
        XCTAssertEqual(summary.clips.map(\.name), ["BAD_A", "BAD_B"])
        for clip in summary.clips {
            XCTAssertNotNil(clip.error, "\(clip.name) should carry its reason")
            XCTAssertEqual(clip.metrics.cropRetention, 0)
            XCTAssertEqual(clip.failures, ["cropRetention"], "a clip that cannot be stabilized fails the crop threshold")
        }
    }

    func testAFailedClipIsAFailureAgainstTheBaseline() async throws {
        try touch("only/BAD.mov", contents: "not a movie")
        let baselineURL = root.appendingPathComponent("baseline.json")
        // The baseline says this clip used to pass.
        try Baseline(
            clips: ["BAD": ClipMetrics(cropRetention: 0.9, residualMotion: 0.2, loopSeamRatio: 1.0)],
            estimator: "registration", solver: "warp"
        ).write(to: baselineURL)

        let exit = try await HarnessRunner.run(arguments: [
            "--fixtures", root.appendingPathComponent("only").path, "--out", root.appendingPathComponent("out").path,
            "--baseline", baselineURL.path,
        ])
        XCTAssertEqual(exit, 1, "a clip that used to pass and now cannot be processed is a regression")
    }

    // MARK: - Arguments

    func testArgumentParsingAcceptsExactlyTheDocumentedFlags() throws {
        let ok = try HarnessRunner.parse(["--fixtures", "f", "--out", "o", "--baseline", "b", "--estimator", "flow", "--solver", "warp", "--update-baseline"])
        XCTAssertEqual(ok.estimator, "flow")
        XCTAssertTrue(ok.updateBaseline)
        XCTAssertEqual(try HarnessRunner.parse(["--fixtures", "f", "--out", "o", "--estimator", "registration-direct"]).estimator, "registration-direct")
        XCTAssertThrowsError(try HarnessRunner.parse(["--fixtures", "f", "--out", "o", "--only", "x"]))
        XCTAssertThrowsError(try HarnessRunner.parse(["--out", "o"]))
        XCTAssertThrowsError(try HarnessRunner.parse(["--fixtures", "f", "--out", "o", "--estimator", "magic"]))
        XCTAssertThrowsError(try HarnessRunner.parse(["--fixtures", "f"]))
    }
}
