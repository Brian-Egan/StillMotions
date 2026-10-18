import Foundation

/// A number the GIF size model looks at. Each is a log or a plain measure of something known before
/// anything is encoded.
public enum SizeTerm: String, CaseIterable, Codable, Sendable {
    case logPixels            // ln(width x height)
    case logGifRate           // ln(frames per second of the GIF)
    case logDetail            // ln(mean brightness gradient + 0.05)
    case logEdgeDensity       // ln(share of strong-edge pixels + 0.005)
    case logChange            // ln(mean frame-to-frame change + 0.05)
    case logChangeFraction    // ln(share of pixels that changed + 0.005)
    case colorEntropy         // bits
    case logCropRetention     // ln(share of the frame the crop keeps)
    case logSourceFrameRate   // ln(the clip's own frame rate)
    case bounce               // 1 for Bounce, else 0
    // Squares of three terms: size does not grow in a straight line with detail, edges or colors.
    case logDetailSquared
    case logEdgeDensitySquared
    case colorEntropySquared
}

/// Everything the estimate is a function of. All of it is known before encoding.
public struct SizeInput: Sendable {
    public var format: ExportFormat
    public var width: Int
    public var height: Int
    /// Frames in the output, after Loop crossfade, Bounce and rate decimation: `PlaybackPlan.steps.count`
    /// for a GIF; the source frame count (`2n - 1` for Bounce) for an MP4.
    public var frameCount: Int
    /// GIF only.
    public var gifRate: GifFrameRate
    public var sourceFrameRate: Double
    /// `CameraPath.cropRetention`.
    public var cropRetention: Double
    public var isBounce: Bool
    /// Measured from the stabilized preview frames. `nil` is allowed (the estimate then assumes a
    /// typical clip and is less accurate), so a number can be shown before the measuring is done.
    public var content: ContentFeatures?

    public init(
        format: ExportFormat, width: Int, height: Int, frameCount: Int, gifRate: GifFrameRate = .fps20,
        sourceFrameRate: Double, cropRetention: Double, isBounce: Bool = false, content: ContentFeatures? = nil
    ) {
        self.format = format
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.gifRate = gifRate
        self.sourceFrameRate = sourceFrameRate
        self.cropRetention = cropRetention
        self.isBounce = isBounce
        self.content = content
    }
}

/// The coefficients behind `SizeEstimator`, kept apart from the arithmetic so the harness can fit
/// new ones from real exports and score them (`stillmotions-harness estimate-accuracy`, issue #31).
///
/// GIF: `ln(bytes / (pixels x frames)) = intercept + sum of weight x term`.
/// MP4: the encoder's own bitrate target times a fitted fraction.
public struct SizeModel: Codable, Equatable, Sendable {
    public var gifIntercept: Double
    public var gifWeights: [SizeTerm: Double]
    /// The content of a typical clip (the mean over the clips the model was fitted on), used when
    /// the real content has not been measured.
    public var typicalContent: ContentFeatures
    /// MP4: how the real file compares with the encoder's bitrate target (1 = exactly on target).
    public var mp4FractionOfTarget: Double

    public init(gifIntercept: Double, gifWeights: [SizeTerm: Double], typicalContent: ContentFeatures, mp4FractionOfTarget: Double) {
        self.gifIntercept = gifIntercept
        self.gifWeights = gifWeights
        self.typicalContent = typicalContent
        self.mp4FractionOfTarget = mp4FractionOfTarget
    }

    /// The value of one term for one export.
    public func value(of term: SizeTerm, for input: SizeInput) -> Double {
        let content = input.content ?? typicalContent
        switch term {
        case .logPixels: return log(Double(max(1, input.width * input.height)))
        case .logGifRate: return log(input.gifRate.framesPerSecond)
        case .logDetail: return log(content.detail + 0.05)
        case .logEdgeDensity: return log(content.edgeDensity + 0.005)
        case .logChange: return log(content.change + 0.05)
        case .logChangeFraction: return log(content.changeFraction + 0.005)
        case .colorEntropy: return content.colorEntropy
        case .logCropRetention: return log(max(0.05, input.cropRetention))
        case .logSourceFrameRate: return log(max(1, input.sourceFrameRate))
        case .bounce: return input.isBounce ? 1 : 0
        case .logDetailSquared: return pow(value(of: .logDetail, for: input), 2)
        case .logEdgeDensitySquared: return pow(value(of: .logEdgeDensity, for: input), 2)
        case .colorEntropySquared: return pow(value(of: .colorEntropy, for: input), 2)
        }
    }

    /// The shipped coefficients. Fitted by `stillmotions-harness estimate-accuracy` (see the PR for
    /// #31 and `docs/ARCHITECTURE.md` §7); rerun it after any change to the encoder or renderer.
    public static let shipped = SizeModel(
        gifIntercept: -3.169902,
        gifWeights: [
            .logPixels: -0.049072,
            .logGifRate: -0.195407,
            .logDetail: 0.030837,
            .logEdgeDensity: 1.184410,
            .logChange: 0.062327,
            .logChangeFraction: 0.045792,
            .colorEntropy: 0.971390,
            .logCropRetention: -0.009863,
            .logSourceFrameRate: 0.465534,
            .bounce: -0.007975,
            .logDetailSquared: -0.063337,
            .logEdgeDensitySquared: 0.220736,
            .colorEntropySquared: -0.073119,
        ],
        typicalContent: ContentFeatures(detail: 9.3982, edgeDensity: 0.3524, change: 4.0831, changeFraction: 0.1249, colorEntropy: 6.9381),
        mp4FractionOfTarget: 1.1267
    )
}

/// Predicts the size of an export from what is known before encoding anything (PRD R-13). It does
/// no encoding and no I/O, so the editor can call it on every settings change.
///
/// The estimate exists to support a Small / Medium / Full choice, not to predict bytes, which is
/// why plus or minus 25% is the bar.
public struct SizeEstimator: Sendable {
    public var model: SizeModel

    public init(model: SizeModel = .shipped) { self.model = model }

    /// The encoder's own target for MP4 (see `VideoEncoder`): bits per pixel per frame, and the
    /// floor it never goes below. The MP4 estimate is that target applied to this clip's size.
    public static let mp4BitsPerPixelPerFrame = 0.08
    public static let mp4MinimumBitRate = 300_000.0

    /// Estimated bytes.
    public func estimate(_ input: SizeInput) -> Int {
        guard input.width > 0, input.height > 0, input.frameCount > 0 else { return 0 }
        let pixels = Double(input.width) * Double(input.height)
        switch input.format {
        case .gif:
            var logBytesPerPixelFrame = model.gifIntercept
            for (term, weight) in model.gifWeights { logBytesPerPixelFrame += weight * model.value(of: term, for: input) }
            return Int((pixels * Double(input.frameCount) * exp(logBytesPerPixelFrame)).rounded())
        case .mp4:
            let rate = max(1, input.sourceFrameRate)
            let bitRate = max(Self.mp4MinimumBitRate, pixels * rate * Self.mp4BitsPerPixelPerFrame)
            return Int((bitRate * (Double(input.frameCount) / rate) / 8 * model.mp4FractionOfTarget).rounded())
        }
    }
}
