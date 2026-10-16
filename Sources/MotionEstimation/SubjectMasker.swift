import CoreImage
import CoreVideo
import Foundation
import Vision

/// Finds the moving subjects a camera estimate must ignore: people, and anything else Vision sees
/// as a foreground instance (which is how pets are covered: Vision has no animal-specific
/// segmentation request).
///
/// A child running through the frame or a dog filling half of it drags the camera estimate toward
/// itself. Masking removes it from the estimate: flow drops the grid samples inside the mask
/// (`OpticalFlowEstimator`), and registration, which has no such hook, gets the subject painted
/// grey (`SubjectMask.blanking`), which is the weaker path (decision 0001).
///
/// Masks are computed on a copy scaled to `analysisLongEdge`, then stored on the fixed
/// `SubjectMask` grid, so one mask serves any estimation size.
public final class SubjectMasker: @unchecked Sendable {
    public struct Configuration {
        /// Long edge, in pixels, the frame is scaled to before segmentation. 720 keeps the cost
        /// low and is plenty for a mask that is stored at 480x270 anyway.
        public var analysisLongEdge: Int
        /// How far the mask is grown, in mask cells (a cell is 4 native pixels on a 1920 wide
        /// frame). Flow and registration are both unreliable right at a moving boundary, so the
        /// exclusion zone has to be larger than the subject.
        public var dilationCells: Int
        /// Above this fraction of the frame the mask is DISCARDED, not applied (PRD R-6). With
        /// that little background left there is nothing to register against, and masking would
        /// make the estimate worse, not better.
        public var maxCoverage: Double
        /// People get Vision's person segmentation, which follows limbs and hair better than the
        /// general foreground mask. `.balanced` is the speed and quality middle.
        public var usesPersonSegmentation: Bool
        public var usesForegroundInstances: Bool

        public init(
            analysisLongEdge: Int = 720,
            dilationCells: Int = 8,
            maxCoverage: Double = 0.6,
            usesPersonSegmentation: Bool = true,
            usesForegroundInstances: Bool = true
        ) {
            self.analysisLongEdge = analysisLongEdge
            self.dilationCells = dilationCells
            self.maxCoverage = maxCoverage
            self.usesPersonSegmentation = usesPersonSegmentation
            self.usesForegroundInstances = usesForegroundInstances
        }
    }

    /// What `mask(for:)` found and what it decided.
    public struct Result {
        /// The mask to apply. EMPTY when `skipped`.
        public let mask: SubjectMask
        /// Coverage of what Vision found, before the skip rule.
        public let rawCoverage: Double
        /// True when the mask covered more than `maxCoverage` and was discarded.
        public let skipped: Bool
    }

    public let configuration: Configuration
    private let context = CIContext()

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func mask(for frame: CVPixelBuffer) async throws -> Result {
        let small = try scaled(frame)
        let handler = ImageRequestHandler(small)
        var combined = SubjectMask.empty

        if configuration.usesPersonSegmentation {
            // The long-standing `VN` request, not `GeneratePersonSegmentationRequest`: that one's
            // result type (`CVReadOnlyPixelBuffer`) exists only in the macOS 27 SDK, and CI builds
            // with an older one (CLAUDE.md). Same model, same quality levels.
            // Synchronous: it blocks this task for tens of milliseconds, which analysis can afford.
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            try VNImageRequestHandler(cvPixelBuffer: small, options: [:]).perform([request])
            var person = SubjectMask.empty
            if let result = request.results?.first {
                person = try SubjectMask.fromSingleChannel(result.pixelBuffer, dilationRadius: configuration.dilationCells)
            }
            combined = combined.union(person)
        }
        if configuration.usesForegroundInstances,
           let observation = try await handler.perform(GenerateForegroundInstanceMaskRequest())
        {
            let buffer = try observation.generateScaledMask(for: observation.allInstances, scaledToImageFrom: handler)
            combined = combined.union(try SubjectMask.fromSingleChannel(buffer, dilationRadius: configuration.dilationCells))
        }
        return Self.apply(skipRule: configuration.maxCoverage, to: combined)
    }

    /// The PRD R-6 skip rule on its own, so it can be tested without Vision.
    public static func apply(skipRule maxCoverage: Double, to mask: SubjectMask) -> Result {
        let coverage = mask.coverage
        if coverage > maxCoverage { return Result(mask: .empty, rawCoverage: coverage, skipped: true) }
        return Result(mask: mask, rawCoverage: coverage, skipped: false)
    }

    private func scaled(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let longEdge = max(width, height)
        guard longEdge > configuration.analysisLongEdge else { return buffer }
        let scale = Double(configuration.analysisLongEdge) / Double(longEdge)
        let newWidth = Int((Double(width) * scale).rounded()), newHeight = Int((Double(height) * scale).rounded())
        var out: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        CVPixelBufferCreate(nil, newWidth, newHeight, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &out)
        guard let small = out else { throw SubjectMaskError("could not allocate \(newWidth)x\(newHeight) pixel buffer") }
        context.render(
            CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale)),
            to: small, bounds: CGRect(x: 0, y: 0, width: newWidth, height: newHeight), colorSpace: nil
        )
        return small
    }
}
