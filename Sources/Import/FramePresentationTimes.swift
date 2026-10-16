import AVFoundation
import CoreVideo
import Foundation

extension FrameSequence {
    /// The presentation time, in seconds, of every frame this sequence yields, by decoding the
    /// same way it does. Decoding rather than counting compressed samples: the decoded count is the
    /// one callers actually receive. Frames are not copied or rotated here, so this is cheap.
    public static func presentationTimes(asset: AVAsset, track: AVAssetTrack) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw ClipImportError.readerFailedToStart(reader.error) }
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        return times
    }
}
