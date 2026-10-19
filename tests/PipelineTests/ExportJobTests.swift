import XCTest
@testable import StillMotionsPipeline

/// #33: running an export end to end: files, progress, cancellation and cleanup.
final class ExportJobTests: XCTestCase {
    static let fixture = "translate-shake"

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func add(_ v: Double) { lock.withLock { values.append(v) } }
        var all: [Double] { lock.withLock { values } }
    }

    private func folders() -> ExportFolders {
        ExportFolders(root: FileManager.default.temporaryDirectory.appendingPathComponent("export-tests-\(UUID().uuidString)", isDirectory: true))
    }

    private func request(
        format: ExportFormat, preset: SizePreset = .small, mode: PlaybackMode = .once, rate: GifFrameRate = .fps20
    ) throws -> (ExportRequest, frameTimes: [Double]) {
        let (motion, size) = try CameraPathTests.motion(fixture: Self.fixture)
        let path = try WarpToReferenceSolver().solve(motion: motion, frameSize: size)
        let times = (0..<motion.count).map { Double($0) / 30 }
        let expected = ExportSizing.frameCount(format: format, mode: mode, gifRate: rate, frameTimes: times, loop: nil)
        let movie = CameraPathTests.fixturesDirectory.appendingPathComponent("\(Self.fixture).mov")
        return (ExportRequest(movieURL: movie, path: path, loop: nil, format: format, preset: preset, mode: mode, gifRate: rate, expectedFrameCount: expected), times)
    }

    func testEveryPresetExportsAsGifAndMp4WithTheFramesThatWerePlanned() async throws {
        let folders = folders()
        defer { folders.purgeLeftovers() }
        for format in ExportFormat.allCases {
            if format == .mp4, !VideoEncoder.isHEVCEncoderAvailable() { continue } // a CI VM may have no HEVC encoder
            for preset in SizePreset.allCases {
                let (request, _) = try request(format: format, preset: preset)
                let file = try await ExportJob.run(request, folders: folders) { _ in }
                XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path), "\(format) \(preset): no file")
                XCTAssertGreaterThan(file.bytes, 0, "\(format) \(preset): empty file")
                XCTAssertEqual(file.url.pathExtension, format == .gif ? "gif" : "mp4")
                XCTAssertEqual(file.frameCount, request.expectedFrameCount, "\(format) \(preset): planned and written frames differ")
                let expectedSize = OutputSize.size(forCrop: request.path.crop, longEdge: preset.longEdge)
                XCTAssertEqual(CGFloat(file.width), expectedSize.width)
                XCTAssertEqual(CGFloat(file.height), expectedSize.height)
                folders.remove(file.folder)
            }
        }
        XCTAssertEqual(folders.folderCount(), 0)
    }

    func testProgressAdvancesInStepsAndEndsAtOne() async throws {
        let folders = folders()
        defer { folders.purgeLeftovers() }
        let seen = Collected()
        let (request, _) = try request(format: .gif)
        _ = try await ExportJob.run(request, folders: folders) { seen.add($0) }
        let values = seen.all
        XCTAssertEqual(values.last, 1)
        XCTAssertEqual(values, values.sorted(), "progress must never go backwards")
        XCTAssertGreaterThan(Set(values).count, 5, "progress should advance in steps, not jump from nothing to done")
        XCTAssertLessThan(values.first ?? 1, 0.5)
    }

    func testCancellingStopsTheExportAndLeavesNothingBehind() async throws {
        let folders = folders()
        defer { folders.purgeLeftovers() }
        let (request, _) = try request(format: .gif, preset: .full)
        final class Holder: @unchecked Sendable { var task: Task<ExportedFile, Error>? }
        let holder = Holder()
        let task = Task { () -> ExportedFile in
            try await ExportJob.run(request, folders: folders) { fraction in
                if fraction >= 0.2 { holder.task?.cancel() }
            }
        }
        holder.task = task
        do {
            _ = try await task.value
            XCTFail("the export should have been cancelled")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(folders.folderCount(), 0, "a cancelled export must leave no folder and no partial file")
    }

    func testLoopAsMp4IsRefusedBeforeAnythingIsWritten() async throws {
        let folders = folders()
        defer { folders.purgeLeftovers() }
        var (request, _) = try request(format: .mp4)
        request.mode = .loop
        do {
            _ = try await ExportJob.run(request, folders: folders) { _ in }
            XCTFail("Loop as MP4 should be refused")
        } catch let error as ExportJobError {
            XCTAssertTrue("\(error)".contains("GIF"))
        }
        XCTAssertEqual(folders.folderCount(), 0)
    }

    func testLeftoverFoldersFromAKilledRunArePurged() throws {
        let folders = folders()
        for _ in 0..<3 { _ = try folders.makeFolder() }
        XCTAssertEqual(folders.folderCount(), 3)
        folders.purgeLeftovers()
        XCTAssertEqual(folders.folderCount(), 0)
    }
}
