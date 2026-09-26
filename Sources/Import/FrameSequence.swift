import AVFoundation
import CoreVideo
import Foundation

/// Streams a video track's frames one at a time, decoded to BGRA pixel buffers. Never
/// holds more than one frame at once — a full-resolution 3s Live Photo is on the order of
/// 90 frames at tens of megabytes each uncompressed, and the full set must never be
/// resident (ARCHITECTURE §3 step 2).
///
/// A plain `Sequence`, not `AsyncSequence`: `AVAssetReader.copyNextSampleBuffer()` already
/// blocks synchronously, so wrapping it in `async` would add ceremony without changing
/// when the work actually happens.
public struct FrameSequence: Sequence {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    public static func make(asset: AVAsset, track: AVAssetTrack) throws -> FrameSequence {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw ClipImportError.readerFailedToStart(reader.error)
        }
        return FrameSequence(reader: reader, output: output)
    }

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        self.reader = reader
        self.output = output
    }

    public func makeIterator() -> Iterator {
        Iterator(reader: reader, output: output)
    }

    public struct Iterator: IteratorProtocol {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput

        public mutating func next() -> CVPixelBuffer? {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { return nil }
            return CMSampleBufferGetImageBuffer(sampleBuffer)
        }
    }
}
