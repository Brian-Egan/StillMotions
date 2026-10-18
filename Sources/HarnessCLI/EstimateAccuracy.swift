import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import StillMotionsPipeline

/// `stillmotions-harness estimate-accuracy --fixtures <dir> --out <dir>` (issue #31).
///
/// Encodes every clip at every size preset, format and GIF frame rate, records the real file sizes,
/// and compares them with `SizeEstimator`. Two steps, so the model can be refitted without
/// re-encoding:
///
///   collect:   encode, write `samples.json`
///   evaluate:  compare the estimator with the samples, write `summary.json` and `summary.md`
///
/// `--samples <file>` skips collecting and evaluates a samples file from an earlier run.
/// The model is judged on clips it was NOT fitted on: `summary` reports a fit on even-numbered
/// clips scored on odd-numbered ones, and the other way round, next to the shipped coefficients.
enum EstimateAccuracy {
    /// One real export.
    struct Sample: Codable {
        let clip: String
        let format: String          // "gif" or "mp4"
        let mode: String            // "loop", "bounce", "once"
        let preset: String
        let rate: String?           // GIF only
        let width: Int
        let height: Int
        let frames: Int             // what the encoder actually wrote
        let plannedFrames: Int      // what the estimator is told
        let sourceFrameRate: Double
        let bytes: Int
        // Clip characteristics, to explain the worst cases. Both are measured on the small loop GIF.
        let detail: Double          // mean absolute gradient, 0...255 per pixel
        let change: Double          // mean absolute difference between consecutive frames, 0...255
        let cropRetention: Double
        /// Measured from the stabilized preview frames, the way the app will (`ContentFeatures`).
        var content: ContentFeatures? = nil
    }

    static let usage = "usage: stillmotions-harness estimate-accuracy --fixtures <dir> --out <dir> [--limit N] [--samples <samples.json>] [--add-content]"

    static func run(arguments: [String]) async throws {
        var fixtures: URL?, out: URL?, samplesFile: URL?
        var limit: Int?
        var addContent = false
        var i = 0
        while i < arguments.count {
            switch arguments[i] {
            case "--fixtures": i += 1; fixtures = URL(fileURLWithPath: arguments[i], isDirectory: true)
            case "--out": i += 1; out = URL(fileURLWithPath: arguments[i], isDirectory: true)
            case "--limit": i += 1; limit = Int(arguments[i])
            case "--samples": i += 1; samplesFile = URL(fileURLWithPath: arguments[i])
            case "--add-content": addContent = true
            default: throw SpikeError("unknown argument '\(arguments[i])'\n\(usage)")
            }
            i += 1
        }
        guard let out else { throw SpikeError("--out is required\n\(usage)") }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let samples: [Sample]
        if let samplesFile {
            var loaded = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: samplesFile))
            if addContent {
                guard let fixtures else { throw SpikeError("--add-content needs --fixtures\n\(usage)") }
                loaded = try await addContentFeatures(to: loaded, fixtures: fixtures)
                try save(loaded, to: out)
            }
            samples = loaded
        } else {
            guard let fixtures else { throw SpikeError("--fixtures is required\n\(usage)") }
            samples = try await collect(fixtures: fixtures, out: out, limit: limit)
        }
        let report = Evaluation(samples: samples)
        try report.markdown.write(to: out.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report.summary).write(to: out.appendingPathComponent("summary.json"))
        print("\n" + report.markdown)
    }

    // MARK: - Content features

    /// Measures a clip's `ContentFeatures` the way the app does: from the stabilized preview frames
    /// (720 px long edge), cropped to the Locked crop.
    static func content(of movieURL: URL, path: CameraPath, sourceSize: CGSize) async throws -> ContentFeatures? {
        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let frames = try FrameSequence.make(asset: asset, track: track)
        let cache = try StabilizedFrameCache.build(frames: frames, corrections: path.corrections, sourceSize: sourceSize, longEdge: 720)
        return cache.contentFeatures(crop: path.crop)
    }

    /// Fills in `content` on samples that lack it, without encoding anything again.
    static func addContentFeatures(to samples: [Sample], fixtures: URL) async throws -> [Sample] {
        let clips = Dictionary(uniqueKeysWithValues: try ClipLocator.find(in: fixtures).map { ($0.name, $0) })
        let renderer = StabilizedRenderer()
        var features: [String: ContentFeatures] = [:]
        let names = Array(Set(samples.map(\.clip))).sorted()
        for (index, name) in names.enumerated() {
            guard let clip = clips[name] else { print("\(name): clip not found, skipped"); continue }
            do {
                let reference = try await clip.referenceIndex()
                let motion = try await ClipAnalyzer.estimateMotion(
                    movieURL: clip.movieURL, referenceIndex: reference, estimator: VisionRegistrationEstimator(),
                    strategy: .chained, renderer: renderer
                )
                let analysis = try await ClipAnalyzer.analyze(movieURL: clip.movieURL, motion: motion, mode: .locked, renderer: renderer)
                if let measured = try await content(of: clip.movieURL, path: analysis.path, sourceSize: motion.size) { features[name] = measured }
                print("[\(index + 1)/\(names.count)] \(name)")
            } catch {
                print("[\(index + 1)/\(names.count)] \(name): FAILED (\(error))")
            }
        }
        return samples.map { sample in
            var copy = sample
            copy.content = features[sample.clip]
            return copy
        }
    }

    // MARK: - Collect

    static func collect(fixtures: URL, out: URL, limit: Int?) async throws -> [Sample] {
        var clips = try ClipLocator.find(in: fixtures)
        guard !clips.isEmpty else { throw SpikeError("no .mov clips found in \(fixtures.path)") }
        if let limit { clips = Array(clips.prefix(limit)) }
        let scratch = out.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let renderer = StabilizedRenderer()
        var samples: [Sample] = []
        for (index, clip) in clips.enumerated() {
            do {
                let started = ContinuousClock.now
                let clipSamples = try await collect(clip: clip, scratch: scratch, renderer: renderer)
                samples += clipSamples
                let seconds = Double((ContinuousClock.now - started).components.seconds)
                print("[\(index + 1)/\(clips.count)] \(clip.name): \(clipSamples.count) exports in \(Int(seconds)) s")
                if (index + 1) % 10 == 0 { try save(samples, to: out) } // a long run survives being interrupted
            } catch {
                print("[\(index + 1)/\(clips.count)] \(clip.name): FAILED (\(error))")
            }
        }
        try save(samples, to: out)
        return samples
    }

    static func save(_ samples: [Sample], to out: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(samples).write(to: out.appendingPathComponent("samples.json"))
    }

    static func collect(clip: ClipInput, scratch: URL, renderer: StabilizedRenderer) async throws -> [Sample] {
        let reference = try await clip.referenceIndex()
        let motion = try await ClipAnalyzer.estimateMotion(
            movieURL: clip.movieURL, referenceIndex: reference, estimator: VisionRegistrationEstimator(),
            strategy: .chained, renderer: renderer
        )
        // Locked, the default: the crop (and so the output size) the app would export by default.
        let analysis = try await ClipAnalyzer.analyze(movieURL: clip.movieURL, motion: motion, mode: .locked, renderer: renderer)
        guard analysis.stabilized else { throw SpikeError("not stabilized: \(analysis.unstabilizedReason ?? "unknown")") }
        let path = analysis.path

        let content = try await content(of: clip.movieURL, path: path, sourceSize: motion.size)
        var found: [Sample] = []
        var clipCharacter: (detail: Double, change: Double)?
        func character(from gif: URL) -> (detail: Double, change: Double) {
            if let clipCharacter { return clipCharacter }
            let measured = ClipCharacter.measure(gif: gif) ?? (0, 0)
            clipCharacter = measured
            return measured
        }

        // GIF: Loop at every preset and rate, and Bounce at one setting (to check the frame count
        // for a mode that doubles it).
        var gifRuns: [(PlaybackMode, SizePreset, GifFrameRate)] = []
        for preset in SizePreset.allCases { for rate in GifFrameRate.allCases { gifRuns.append((.loop, preset, rate)) } }
        gifRuns.append((.bounce, .medium, .fps20))
        for (mode, preset, rate) in gifRuns {
            let url = scratch.appendingPathComponent("\(clip.name)-\(mode.rawValue)-\(preset.rawValue)-\(rate.rawValue).gif")
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try await ClipExporter.exportGIF(
                movieURL: clip.movieURL, path: path, preset: preset, frameRate: rate, mode: mode,
                loop: mode == .loop ? analysis.loop : nil, to: url, renderer: renderer
            )
            let planned = PlaybackPlan.make(mode: mode, frameTimes: motion.frameTimes, loop: analysis.loop, frameRate: rate).steps.count
            let measured = (mode == .loop && preset == .small && rate == .fps20) ? character(from: url) : (clipCharacter?.detail ?? 0, clipCharacter?.change ?? 0)
            found.append(Sample(
                clip: clip.name, format: "gif", mode: mode.rawValue, preset: preset.rawValue, rate: rate.rawValue,
                width: result.width, height: result.height, frames: result.frameCount, plannedFrames: planned,
                sourceFrameRate: motion.frameRate, bytes: HarnessRunner.fileSize(url) ?? 0,
                detail: measured.0, change: measured.1, cropRetention: path.cropRetention, content: content
            ))
        }

        // MP4: Once at every preset, and Bounce at one.
        var videoRuns: [(PlaybackMode, SizePreset)] = SizePreset.allCases.map { (.once, $0) }
        videoRuns.append((.bounce, .medium))
        for (mode, preset) in videoRuns {
            let url = scratch.appendingPathComponent("\(clip.name)-\(mode.rawValue)-\(preset.rawValue).mp4")
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try await ClipExporter.exportVideo(
                movieURL: clip.movieURL, path: path, preset: preset, mode: mode, to: url, renderer: renderer
            )
            let n = motion.motion.count
            found.append(Sample(
                clip: clip.name, format: "mp4", mode: mode.rawValue, preset: preset.rawValue, rate: nil,
                width: result.width, height: result.height, frames: result.frameCount,
                plannedFrames: mode == .bounce ? max(1, 2 * n - 1) : n,
                sourceFrameRate: motion.frameRate, bytes: HarnessRunner.fileSize(url) ?? 0,
                detail: clipCharacter?.detail ?? 0, change: clipCharacter?.change ?? 0, cropRetention: path.cropRetention, content: content
            ))
        }
        return found
    }
}

/// Cheap measures of a clip's content, taken from its small GIF: how much fine detail each frame
/// has, and how much changes from one frame to the next. These are what make a GIF large or small,
/// so they explain the estimator's worst cases.
enum ClipCharacter {
    static func measure(gif url: URL, maxFrames: Int = 12, sampleWidth: Int = 160) -> (detail: Double, change: Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = min(CGImageSourceGetCount(source), maxFrames)
        guard count > 0 else { return nil }
        var detail = 0.0, change = 0.0, changePairs = 0
        var previous: [UInt8]?
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let width = sampleWidth
            let height = max(1, Int((Double(image.height) / Double(image.width) * Double(width)).rounded()))
            var gray = [UInt8](repeating: 0, count: width * height)
            let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.interpolationQuality = .medium
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { continue }
            // Mean absolute horizontal + vertical gradient.
            var gradient = 0
            for y in 0..<(height - 1) {
                for x in 0..<(width - 1) {
                    let p = Int(gray[y * width + x])
                    gradient += abs(p - Int(gray[y * width + x + 1])) + abs(p - Int(gray[(y + 1) * width + x]))
                }
            }
            detail += Double(gradient) / Double((width - 1) * (height - 1) * 2)
            if let previous, previous.count == gray.count {
                var diff = 0
                for k in 0..<gray.count { diff += abs(Int(gray[k]) - Int(previous[k])) }
                change += Double(diff) / Double(gray.count)
                changePairs += 1
            }
            previous = gray
        }
        return (detail / Double(count), changePairs > 0 ? change / Double(changePairs) : 0)
    }
}
