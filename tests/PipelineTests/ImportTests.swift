import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import StillMotionsPipeline

final class ImportTests: XCTestCase {
    static let fixtureNames = [
        "translate-linear", "translate-shake", "rotate", "scale",
        "combined", "periodic", "moving-subject", "parallax",
    ]

    static let fixturesDirectory: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("fixtures/synthetic", isDirectory: true)
    }()

    // MARK: - Frame count, against every committed synthetic fixture (#7)

    func testFrameCountMatchesEverySyntheticFixture() async throws {
        // The generator's committed fixtures have no paired HEIC — #7 is video-only ground
        // truth for the tracker/solver. The importer needs a still to pair with, so this
        // test provides a throwaway one; only the MOV side is under test here.
        let placeholderHEIC = try Self.makeHEICStill()
        defer { try? FileManager.default.removeItem(at: placeholderHEIC) }

        for name in Self.fixtureNames {
            let movURL = Self.fixturesDirectory.appendingPathComponent("\(name).mov")
            let truth = try FixtureTruth.load(from: Self.fixturesDirectory.appendingPathComponent("\(name).truth.json"))
            let descriptor = try await LivePhotoImporter.describeClip(heicURL: placeholderHEIC, movURL: movURL)
            XCTAssertEqual(descriptor.frameCount, truth.frameCount, "\(name): frame count mismatch")
            XCTAssertEqual(descriptor.width, truth.width, "\(name): width mismatch")
            XCTAssertEqual(descriptor.height, truth.height, "\(name): height mismatch")
        }
    }

    // MARK: - Reference frame index (#8 acceptance: derived, not hardcoded)

    func testReferenceFrameIndexIsDerivedFromExifCaptureTime() async throws {
        let frameCount = 60
        let frameRate = 30.0
        // Deliberately neither 0 nor the midpoint (30), so a hardcoded guess would fail.
        let stillFrameIndex = 41
        let stillTime = Double(stillFrameIndex) / frameRate

        let clip = try Self.makeTestClip(frameCount: frameCount, frameRate: frameRate, stillOffsetSeconds: stillTime)
        defer { try? FileManager.default.removeItem(at: clip.directory) }

        let descriptor = try await LivePhotoImporter.describeClip(heicURL: clip.heic, movURL: clip.mov)
        XCTAssertEqual(descriptor.referenceFrameIndex, stillFrameIndex)
        XCTAssertNotEqual(descriptor.referenceFrameIndex, 0)
        XCTAssertNotEqual(descriptor.referenceFrameIndex, frameCount / 2)
    }

    func testReferenceFrameIndexFallsBackToZeroWithoutAMarker() async throws {
        let clip = try Self.makeTestClip(frameCount: 30, frameRate: 30.0, stillOffsetSeconds: nil)
        defer { try? FileManager.default.removeItem(at: clip.directory) }

        let descriptor = try await LivePhotoImporter.describeClip(heicURL: clip.heic, movURL: clip.mov)
        XCTAssertEqual(descriptor.referenceFrameIndex, 0)
    }

    // MARK: - Malformed / unpaired input (#8 acceptance)

    func testMissingMovieThrowsADescriptiveError() async throws {
        let heic = try Self.makeHEICStill()
        defer { try? FileManager.default.removeItem(at: heic) }
        let nonexistentMov = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).mov")

        do {
            _ = try await LivePhotoImporter.describeClip(heicURL: heic, movURL: nonexistentMov)
            XCTFail("expected missingFile to be thrown")
        } catch let error as ClipImportError {
            XCTAssertTrue(error.description.contains(nonexistentMov.lastPathComponent), "error should name the missing file: \(error)")
        }
    }

    func testUnreadableStillThrowsADescriptiveError() async throws {
        let clip = try Self.makeTestClip(frameCount: 10, frameRate: 30.0, stillOffsetSeconds: nil)
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let notAnImage = clip.directory.appendingPathComponent("not-a-photo.heic")
        try Data("not actually a HEIC file".utf8).write(to: notAnImage)

        do {
            _ = try await LivePhotoImporter.describeClip(heicURL: notAnImage, movURL: clip.mov)
            XCTFail("expected unreadableStill to be thrown")
        } catch let error as ClipImportError {
            XCTAssertTrue(error.description.contains("not-a-photo.heic"), "error should name the unreadable file: \(error)")
        }
    }

    // MARK: - Streaming decode: bounded memory (#8 acceptance)

    func testDecodingALongerClipDoesNotGrowResidentMemoryLinearly() async throws {
        // 8s at 30fps: long enough that "holding every frame" (240 * ~64x64x4 bytes is
        // tiny, so use a larger frame) would be visible against "holding one at a time".
        let frameCount = 240
        let clip = try Self.makeTestClip(frameCount: frameCount, frameRate: 30.0, frameSize: CGSize(width: 640, height: 480), stillOffsetSeconds: nil)
        defer { try? FileManager.default.removeItem(at: clip.directory) }

        let asset = AVURLAsset(url: clip.mov)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let sequence = try FrameSequence.make(asset: asset, track: track)

        let baseline = ProcessMemory.residentBytes()
        var peakGrowth: Int64 = 0
        var decoded = 0
        for pixelBuffer in sequence {
            _ = pixelBuffer
            decoded += 1
            let growth = ProcessMemory.residentBytes() - baseline
            peakGrowth = max(peakGrowth, growth)
        }
        XCTAssertEqual(decoded, frameCount)

        // One 640x480 BGRA frame is ~1.2 MB. If every frame were retained simultaneously
        // that would be ~295 MB; bounded streaming should stay within a small multiple of
        // a single frame, not scale with frameCount. 20 MB is generous headroom for
        // decoder buffering while still catching "the whole clip is resident".
        let singleFrameBudget: Int64 = 20 * 1024 * 1024
        XCTAssertLessThan(peakGrowth, singleFrameBudget, "resident memory grew by \(peakGrowth) bytes decoding \(frameCount) frames — looks like frames are being retained rather than streamed")
    }

    // MARK: - Test fixture helpers

    static func makeHEICStill(size: CGSize = CGSize(width: 64, height: 64)) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).heic")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil) else {
            throw ClipImportError.unreadableStill(url)
        }
        let context = CIContext()
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: size))
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw ClipImportError.unreadableStill(url)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ClipImportError.unreadableStill(url)
        }
        return url
    }

    struct TestClip {
        let directory: URL
        let heic: URL
        let mov: URL
    }

    /// A fixed reference instant for the MOV's creation date. Real seconds-since-epoch, not
    /// `.zero`, since `AVMutableMetadataItem`'s date value round-trips through an `NSDate`.
    static let testClipCreationDate = Date(timeIntervalSince1970: 1_735_000_000)

    static func makeTestClip(
        frameCount: Int,
        frameRate: Double,
        frameSize: CGSize = CGSize(width: 64, height: 64),
        stillOffsetSeconds: Double?
    ) throws -> TestClip {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let movURL = directory.appendingPathComponent("clip.mov")
        let heicURL = directory.appendingPathComponent("clip.heic")

        let writer = try AVAssetWriter(outputURL: movURL, fileType: .mov)
        let creationItem = AVMutableMetadataItem()
        creationItem.identifier = .commonIdentifierCreationDate
        creationItem.value = Self.testClipCreationDate as NSDate
        writer.metadata = [creationItem]

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(frameSize.width),
            AVVideoHeightKey: Int(frameSize.height),
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(frameSize.width),
            kCVPixelBufferHeightKey as String: Int(frameSize.height),
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let context = CIContext()
        let queue = DispatchQueue(label: "test-clip-writer.\(UUID())")
        let progress = TestClipWriteProgress()
        let done = DispatchSemaphore(value: 0)
        let timescale: Int32 = 600
        let frameDuration = Int64((Double(timescale) / frameRate).rounded())

        input.requestMediaDataWhenReady(on: queue) {
            guard !progress.finished else { return }
            while input.isReadyForMoreMediaData, progress.nextIndex < frameCount {
                guard let pool = adaptor.pixelBufferPool else { break }
                var pixelBufferOut: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
                guard let pixelBuffer = pixelBufferOut else { break }
                let hue = Double(progress.nextIndex) / Double(max(frameCount - 1, 1))
                let color = CIColor(red: hue, green: 1 - hue, blue: 0.5)
                let image = CIImage(color: color).cropped(to: CGRect(origin: .zero, size: frameSize))
                context.render(image, to: pixelBuffer, bounds: CGRect(origin: .zero, size: frameSize), colorSpace: nil)
                let time = CMTime(value: CMTimeValue(progress.nextIndex) * CMTimeValue(frameDuration), timescale: timescale)
                adaptor.append(pixelBuffer, withPresentationTime: time)
                progress.nextIndex += 1
            }
            if progress.nextIndex >= frameCount {
                progress.finished = true
                input.markAsFinished()
                done.signal()
            }
        }
        done.wait()

        let finishDone = DispatchSemaphore(value: 0)
        writer.finishWriting { finishDone.signal() }
        finishDone.wait()

        guard let destination = CGImageDestinationCreateWithURL(heicURL as CFURL, "public.heic" as CFString, 1, nil) else {
            throw ClipImportError.unreadableStill(heicURL)
        }
        let stillImage = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: frameSize))
        let cgImage = context.createCGImage(stillImage, from: stillImage.extent)!

        var properties: [CFString: Any] = [:]
        if let stillOffsetSeconds {
            let stillDate = Self.testClipCreationDate.addingTimeInterval(stillOffsetSeconds)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.timeZone = TimeZone(identifier: "UTC")
            let wholeSecondDate = Date(timeIntervalSince1970: stillDate.timeIntervalSince1970.rounded(.down))
            let subseconds = stillDate.timeIntervalSince1970 - wholeSecondDate.timeIntervalSince1970
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal: formatter.string(from: wholeSecondDate),
                kCGImagePropertyExifSubsecTimeOriginal: String(Int((subseconds * 1000).rounded())),
            ] as [CFString: Any]
        }
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        CGImageDestinationFinalize(destination)

        return TestClip(directory: directory, heic: heicURL, mov: movURL)
    }
}

private final class TestClipWriteProgress: @unchecked Sendable {
    var nextIndex = 0
    var finished = false
}

/// Resident set size, for the streaming-decode memory test. Darwin-only (`swift test` on
/// macOS is the only place this test runs — PRD R-24).
enum ProcessMemory {
    static func residentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Int64(info.resident_size)
    }
}
