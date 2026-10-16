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

    func testReferenceFrameIndexComesFromTheStillImageTimeMetadataTrack() async throws {
        // The real-file path: a Live Photo's MOV has a timed metadata track whose
        // `still-image-time` sample sits at the still's moment (measured on real files). No EXIF
        // marker at all here, so this can only come from the track.
        let stillFrameIndex = 41
        let clip = try Self.makeTestClip(
            frameCount: 60, frameRate: 30.0, stillOffsetSeconds: nil, stillImageTime: Double(stillFrameIndex) / 30.0
        )
        defer { try? FileManager.default.removeItem(at: clip.directory) }

        let descriptor = try await LivePhotoImporter.describeClip(heicURL: clip.heic, movURL: clip.mov)
        XCTAssertEqual(descriptor.referenceFrameIndex, stillFrameIndex)
    }

    func testTheMetadataTrackWinsOverAConflictingExifTime() async throws {
        // EXIF says frame 10, the movie's own marker says frame 41. The marker is exact; EXIF is
        // only good to about a second.
        let clip = try Self.makeTestClip(
            frameCount: 60, frameRate: 30.0, stillOffsetSeconds: 10.0 / 30.0, stillImageTime: 41.0 / 30.0
        )
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let descriptor = try await LivePhotoImporter.describeClip(heicURL: clip.heic, movURL: clip.mov)
        XCTAssertEqual(descriptor.referenceFrameIndex, 41)
    }

    func testExifLocalTimeIsInterpretedWithItsUTCOffset() async throws {
        // What a real Live Photo does: the HEIC's EXIF time is LOCAL with a separate
        // `OffsetTimeOriginal`, the movie's date is absolute. Reading the local time as UTC put
        // every real clip's still four hours before its movie and clamped it to frame 0.
        let clip = try Self.makeTestClip(
            frameCount: 60, frameRate: 30.0, stillOffsetSeconds: 41.0 / 30.0, exifUTCOffset: "-04:00"
        )
        defer { try? FileManager.default.removeItem(at: clip.directory) }
        let descriptor = try await LivePhotoImporter.describeClip(heicURL: clip.heic, movURL: clip.mov)
        XCTAssertEqual(descriptor.referenceFrameIndex, 41)
    }

    func testStillTimeMapsToTheNearestActualFrameTimeNotTimeTimesFrameRate() {
        // A variable-frame-rate clip: 30 fps, then a slow stretch, then 30 fps again. At the
        // nominal average rate, 1.20 s would be frame 36; the frame actually nearest is 33.
        let times: [Double] = [0, 0.033, 0.066, 0.1, 0.133, 0.166, 0.5, 0.8, 1.1, 1.15, 1.2 + 0.001, 1.233, 1.266]
        let index = LivePhotoImporter.nearestFrame(to: 1.2, in: times)
        XCTAssertEqual(index, 10)
        XCTAssertEqual(LivePhotoImporter.nearestFrame(to: nil, in: times), 0, "no marker means frame 0")
        XCTAssertEqual(LivePhotoImporter.nearestFrame(to: -3, in: times), 0)
        XCTAssertEqual(LivePhotoImporter.nearestFrame(to: 99, in: times), times.count - 1)
        XCTAssertEqual(LivePhotoImporter.nearestFrame(to: 0.5, in: []), 0)
    }

    func testUTCOffsetParsing() {
        XCTAssertEqual(LivePhotoImporter.offsetSeconds("-04:00"), -4 * 3600)
        XCTAssertEqual(LivePhotoImporter.offsetSeconds("+05:30"), 5.5 * 3600)
        XCTAssertEqual(LivePhotoImporter.offsetSeconds("+00:00"), 0)
        XCTAssertEqual(LivePhotoImporter.offsetSeconds(nil), 0)
        XCTAssertEqual(LivePhotoImporter.offsetSeconds("garbage"), 0)
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
        stillOffsetSeconds: Double?,
        /// Writes the movie's timed `still-image-time` metadata track at this time, as a real
        /// Live Photo has.
        stillImageTime: Double? = nil,
        /// Writes the EXIF time as LOCAL time in this offset (`"-04:00"`) with `OffsetTimeOriginal`,
        /// as a real Live Photo does. nil writes UTC with no offset (the older test convention).
        exifUTCOffset: String? = nil
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

        var stillMetadata: (input: AVAssetWriterInput, adaptor: AVAssetWriterInputMetadataAdaptor)?
        if stillImageTime != nil {
            let identifier = "mdta/com.apple.quicktime.still-image-time"
            let specifications: [[String: Any]] = [[
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: identifier,
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: "com.apple.metadata.datatype.int8",
            ]]
            var format: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: specifications as CFArray, formatDescriptionOut: &format
            )
            let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
            writer.add(metadataInput)
            stillMetadata = (metadataInput, AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput))
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        if let stillImageTime, let stillMetadata {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(rawValue: "mdta/com.apple.quicktime.still-image-time")
            item.dataType = "com.apple.metadata.datatype.int8"
            item.value = NSNumber(value: -1) // what real files carry; the time is the sample's, not this value
            stillMetadata.adaptor.append(AVTimedMetadataGroup(
                items: [item],
                timeRange: CMTimeRange(start: CMTime(seconds: stillImageTime, preferredTimescale: 600), duration: CMTime(value: 1, timescale: 600))
            ))
            stillMetadata.input.markAsFinished()
        }

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
            // Local wall-clock time in the given offset, as a real camera writes it.
            formatter.timeZone = TimeZone(secondsFromGMT: Int(LivePhotoImporter.offsetSeconds(exifUTCOffset)))
            let wholeSecondDate = Date(timeIntervalSince1970: stillDate.timeIntervalSince1970.rounded(.down))
            let subseconds = stillDate.timeIntervalSince1970 - wholeSecondDate.timeIntervalSince1970
            var exif: [CFString: Any] = [
                kCGImagePropertyExifDateTimeOriginal: formatter.string(from: wholeSecondDate),
                kCGImagePropertyExifSubsecTimeOriginal: String(Int((subseconds * 1000).rounded())),
            ]
            if let exifUTCOffset { exif[kCGImagePropertyExifOffsetTimeOriginal] = exifUTCOffset }
            properties[kCGImagePropertyExifDictionary] = exif
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
