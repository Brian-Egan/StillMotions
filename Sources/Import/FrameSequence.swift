import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// Streams a video track's frames one at a time, decoded to BGRA pixel buffers. Never
/// holds more than one frame at once — a full-resolution 3s Live Photo is on the order of
/// 90 frames at tens of megabytes each uncompressed, and the full set must never be
/// resident (ARCHITECTURE §3 step 2).
///
/// Frames come out UPRIGHT: if the track carries a rotation (every portrait Live Photo does), each
/// frame is turned by it as it is decoded, so a portrait clip arrives as portrait. A track with no
/// rotation takes the original path, with no copy and no extra work. Rotated frames are rendered
/// into a fresh buffer one at a time, so memory stays independent of clip length.
///
/// A plain `Sequence`, not `AsyncSequence`: `AVAssetReader.copyNextSampleBuffer()` already
/// blocks synchronously, so wrapping it in `async` would add ceremony without changing
/// when the work actually happens.
public struct FrameSequence: Sequence {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let orientation: TrackOrientation

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
        return FrameSequence(reader: reader, output: output, orientation: TrackOrientation.current(of: track))
    }

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, orientation: TrackOrientation) {
        self.reader = reader
        self.output = output
        self.orientation = orientation
    }

    public func makeIterator() -> Iterator {
        Iterator(reader: reader, output: output, orientation: orientation, context: CIContext())
    }

    public struct Iterator: IteratorProtocol {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let orientation: TrackOrientation
        let context: CIContext

        public mutating func next() -> CVPixelBuffer? {
            guard let sampleBuffer = output.copyNextSampleBuffer(),
                  let stored = CMSampleBufferGetImageBuffer(sampleBuffer)
            else { return nil }
            guard orientation != .up else { return stored }
            return upright(stored) ?? stored
        }

        /// A new buffer holding `stored` turned upright, or nil if one could not be allocated.
        private func upright(_ stored: CVPixelBuffer) -> CVPixelBuffer? {
            let image = CIImage(cvPixelBuffer: stored).oriented(orientation.cgOrientation)
            let width = Int(image.extent.width.rounded()), height = Int(image.extent.height.rounded())
            var out: CVPixelBuffer?
            let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &out)
            guard let buffer = out else { return nil }
            // Name the output space. Core Image works in linear light, and a render that names none
            // stores linear numbers that everything downstream reads as sRGB: a portrait clip came out
            // too dark (#90). Tagging the buffer lets later readers interpret it the same way.
            let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
            context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: sRGB)
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
            return buffer
        }
    }
}
