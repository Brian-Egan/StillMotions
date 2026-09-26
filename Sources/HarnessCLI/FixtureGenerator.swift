import AVFoundation
import CoreImage
import Foundation
import StillMotionsPipeline

/// Generates the committed synthetic fixtures (PRD R-21): MOV clips synthesized by
/// sampling a large textured canvas through a known per-frame transform, plus a sidecar
/// recording that exact transform. Every unit test of the tracker, solver, and loop
/// selector needs this ground truth — real Live Photos have no known camera path.
enum FixtureGenerator {
    static let outputSize = CGSize(width: 1920, height: 1080)
    static let frameRate: Int32 = 30
    static let frameCount = 90 // 3 s at 30 fps
    static let canvasOrigin = CGPoint(x: CGFloat(SyntheticCanvas.margin), y: CGFloat(SyntheticCanvas.margin))
    static let canvasSize = CGSize(
        width: outputSize.width + CGFloat(SyntheticCanvas.margin) * 2,
        height: outputSize.height + CGFloat(SyntheticCanvas.margin) * 2
    )
    static let center = CGPoint(x: outputSize.width / 2, y: outputSize.height / 2)

    /// A single warped source. `transform` maps the reference frame's coordinates onto
    /// this frame's coordinates for THIS layer (see `FixtureTruth`'s doc comment). Layers
    /// composite bottom to top; the first layer's transform is recorded as fixture truth.
    struct Layer {
        let source: CIImage
        let transform: (Int) -> CGAffineTransform
    }

    struct FixtureSpec {
        let name: String
        let layers: [Layer]
    }

    static func run(arguments: [String]) throws {
        guard let outPath = value(for: "--out", in: arguments) else {
            throw FixtureGeneratorError.missingArgument("--out")
        }
        let outDir = URL(fileURLWithPath: outPath, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let background = SyntheticCanvas.background(outputSize: outputSize)
        let near = SyntheticCanvas.nearLayer(outputSize: outputSize)

        let objectRect = CGRect(x: canvasOrigin.x + 150, y: canvasOrigin.y + 150, width: 160, height: 160)
        let object = SyntheticCanvas.foregroundObject(
            size: canvasSize, rect: objectRect, color: CIColor(red: 1.0, green: 0.55, blue: 0.0)
        )

        let shake = shakeOffsets(seed: 0xC0FFEE_1234, count: frameCount, magnitude: 8.0)

        let specs: [FixtureSpec] = [
            FixtureSpec(name: "translate-linear", layers: [
                Layer(source: background, transform: translateLinear),
            ]),
            FixtureSpec(name: "translate-shake", layers: [
                Layer(source: background, transform: { translateShake($0, offsets: shake) }),
            ]),
            FixtureSpec(name: "rotate", layers: [
                Layer(source: background, transform: rotate),
            ]),
            FixtureSpec(name: "scale", layers: [
                Layer(source: background, transform: scaleFixture),
            ]),
            FixtureSpec(name: "combined", layers: [
                Layer(source: background, transform: combined),
            ]),
            FixtureSpec(name: "periodic", layers: [
                Layer(source: background, transform: periodic),
            ]),
            FixtureSpec(name: "moving-subject", layers: [
                Layer(source: background, transform: { translateShake($0, offsets: shake) }),
                Layer(source: object, transform: objectMotion),
            ]),
            FixtureSpec(name: "parallax", layers: [
                Layer(source: background, transform: farMotion),
                Layer(source: near, transform: nearMotion),
            ]),
        ]

        let context = CIContext()
        for spec in specs {
            print("generating \(spec.name)...")
            let movURL = outDir.appendingPathComponent("\(spec.name).mov")
            try writeMovie(
                frameCount: frameCount,
                size: outputSize,
                frameRate: frameRate,
                context: context,
                render: { index in render(spec: spec, index: index) },
                to: movURL
            )
            try MovieDeterminism.neutralize(fileAt: movURL)

            let truthFrames = (0..<frameCount).map { index -> FixtureTruth.FrameTruth in
                FixtureTruth.FrameTruth(index: index, transform: matrixRows(spec.layers[0].transform(index)))
            }
            let truth = FixtureTruth(
                name: spec.name,
                width: Int(outputSize.width),
                height: Int(outputSize.height),
                frameRate: Double(frameRate),
                frameCount: frameCount,
                referenceFrameIndex: 0,
                frames: truthFrames
            )
            try truth.write(to: outDir.appendingPathComponent("\(spec.name).truth.json"))
        }
        print("done: \(specs.count) fixtures written to \(outDir.path)")
    }

    // MARK: - Rendering

    static func render(spec: FixtureSpec, index: Int) -> CIImage {
        var composite: CIImage?
        let frameRect = CGRect(origin: .zero, size: outputSize)
        for layer in spec.layers {
            let forward = layer.transform(index)
            let sampleTransform = CGAffineTransform(translationX: -canvasOrigin.x, y: -canvasOrigin.y)
                .concatenating(forward)
            let warped = layer.source.transformed(by: sampleTransform).cropped(to: frameRect)
            composite = composite.map { warped.composited(over: $0) } ?? warped
        }
        return (composite ?? CIImage(color: .black).cropped(to: frameRect)).cropped(to: frameRect)
    }

    static func aboutCenter(_ t: CGAffineTransform) -> CGAffineTransform {
        CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(t)
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    static func fraction(_ index: Int) -> Double {
        Double(index) / Double(frameCount - 1)
    }

    // MARK: - Per-fixture motion

    static func translateLinear(_ index: Int) -> CGAffineTransform {
        CGAffineTransform(translationX: CGFloat(40.0 * fraction(index)), y: 0)
    }

    static func shakeOffsets(seed: UInt64, count: Int, magnitude: Double) -> [(Double, Double)] {
        var rng = DeterministicRNG(seed: seed)
        return (0..<count).map { _ in (rng.nextSigned(magnitude: magnitude), rng.nextSigned(magnitude: magnitude)) }
    }

    static func translateShake(_ index: Int, offsets: [(Double, Double)]) -> CGAffineTransform {
        let (dx, dy) = offsets[index]
        return CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy))
    }

    static func rotate(_ index: Int) -> CGAffineTransform {
        let angle = (3.0 * Double.pi / 180.0) * fraction(index)
        return aboutCenter(CGAffineTransform(rotationAngle: CGFloat(angle)))
    }

    static func scaleFixture(_ index: Int) -> CGAffineTransform {
        let s = 1.0 + 0.04 * fraction(index)
        return aboutCenter(CGAffineTransform(scaleX: CGFloat(s), y: CGFloat(s)))
    }

    static func combined(_ index: Int) -> CGAffineTransform {
        let f = fraction(index)
        let angle = (3.0 * Double.pi / 180.0) * f
        let s = 1.0 + 0.04 * f
        let rotateScale = CGAffineTransform(scaleX: CGFloat(s), y: CGFloat(s))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(angle)))
        return aboutCenter(rotateScale)
            .concatenating(CGAffineTransform(translationX: CGFloat(40.0 * f), y: 0))
    }

    static func periodic(_ index: Int) -> CGAffineTransform {
        let phase = 2.0 * Double.pi * Double(index) / 45.0
        let dx = 15.0 * sin(phase)
        let dy = 10.0 * sin(phase + .pi / 2)
        return CGAffineTransform(translationX: CGFloat(dx), y: CGFloat(dy))
    }

    static func objectMotion(_ index: Int) -> CGAffineTransform {
        let f = fraction(index)
        return CGAffineTransform(translationX: CGFloat(1500.0 * f), y: CGFloat(650.0 * f))
    }

    static func farMotion(_ index: Int) -> CGAffineTransform {
        CGAffineTransform(translationX: CGFloat(15.0 * fraction(index)), y: 0)
    }

    static func nearMotion(_ index: Int) -> CGAffineTransform {
        CGAffineTransform(translationX: CGFloat(90.0 * fraction(index)), y: 0)
    }

    // MARK: - Truth encoding

    /// Row-major 3x3 homogeneous matrix matching `CGAffineTransform`'s point mapping
    /// `x' = a*x + c*y + tx`, `y' = b*x + d*y + ty`.
    static func matrixRows(_ t: CGAffineTransform) -> [[Double]] {
        [
            [Double(t.a), Double(t.c), Double(t.tx)],
            [Double(t.b), Double(t.d), Double(t.ty)],
            [0, 0, 1],
        ]
    }

    // MARK: - Argument parsing

    static func value(for flag: String, in arguments: [String]) -> String? {
        guard let flagIndex = arguments.firstIndex(of: flag), flagIndex + 1 < arguments.count else {
            return nil
        }
        return arguments[flagIndex + 1]
    }
}

enum FixtureGeneratorError: Error, CustomStringConvertible {
    case missingArgument(String)
    case writerSetupFailed
    case writerFailed(Error?)

    var description: String {
        switch self {
        case .missingArgument(let flag):
            return "missing required argument \(flag)"
        case .writerSetupFailed:
            return "could not add video input to asset writer"
        case .writerFailed(let error):
            return "asset writer failed: \(error?.localizedDescription ?? "unknown error")"
        }
    }
}

/// Mutable state for the asset-writer's `requestMediaDataWhenReady` callback, boxed so the
/// concurrency checker sees one `Sendable` reference rather than captured `var`s — the
/// callback always runs serially on `queue`, so a single box is safe.
final class WriteProgress: @unchecked Sendable {
    var nextIndex = 0
    var finished = false
}

/// Writes `frameCount` frames, produced by `render`, to a streamed H.264 `.mov` at `url`.
func writeMovie(
    frameCount: Int,
    size: CGSize,
    frameRate: Int32,
    context: CIContext,
    render: @escaping (Int) -> CIImage,
    to url: URL
) throws {
    if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
    }

    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let videoSettings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width),
        AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 2_500_000,
            AVVideoExpectedSourceFrameRateKey: Int(frameRate),
            AVVideoMaxKeyFrameIntervalKey: Int(frameRate),
            // Baseline disallows B-frames, so decode order equals presentation order and
            // the writer needs no edit list. Simpler fixtures for exact per-frame testing,
            // and it sidesteps an AVAssetReader/edit-list interaction that otherwise
            // returns more sample buffers than the track's sample table actually has.
            AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
        ] as [String: Any],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    input.expectsMediaDataInRealTime = false

    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(size.width),
        kCVPixelBufferHeightKey as String: Int(size.height),
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)

    guard writer.canAdd(input) else {
        throw FixtureGeneratorError.writerSetupFailed
    }
    writer.add(input)

    guard writer.startWriting() else {
        throw FixtureGeneratorError.writerFailed(writer.error)
    }
    writer.startSession(atSourceTime: .zero)

    let queue = DispatchQueue(label: "fixture-writer.\(url.lastPathComponent)")
    let doneSemaphore = DispatchSemaphore(value: 0)
    let progress = WriteProgress()

    input.requestMediaDataWhenReady(on: queue) {
        guard !progress.finished else { return }
        while input.isReadyForMoreMediaData, progress.nextIndex < frameCount {
            guard let pool = adaptor.pixelBufferPool else { break }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { break }
            let image = render(progress.nextIndex)
            context.render(image, to: pixelBuffer, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
            let time = CMTime(value: CMTimeValue(progress.nextIndex), timescale: frameRate)
            adaptor.append(pixelBuffer, withPresentationTime: time)
            progress.nextIndex += 1
        }
        if progress.nextIndex >= frameCount {
            progress.finished = true
            input.markAsFinished()
            doneSemaphore.signal()
        }
    }
    doneSemaphore.wait()

    let finishSemaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { finishSemaphore.signal() }
    finishSemaphore.wait()

    if writer.status != .completed {
        throw FixtureGeneratorError.writerFailed(writer.error)
    }
}
