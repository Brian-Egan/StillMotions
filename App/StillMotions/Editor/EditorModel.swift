import AVFoundation
import CoreImage
import Observation
import Photos
import StillMotionsPipeline
import os

/// The editor's state: it opens a Live Photo, solves it ONCE into a stabilized frame cache, and
/// then plays that cache in the chosen mode at the chosen rate (ARCHITECTURE §5).
///
/// Changing the mode or the frame rate only re-plans which cached frames play in which order
/// (`PlaybackPlan`), so it is instant and never solves again. `analyzeCount` counts solves, and
/// the UI tests hold it at 1 across any number of switches.
@MainActor
@Observable
final class EditorModel {
    enum Phase: Equatable {
        case loading(String)
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading("Preparing")
    private(set) var plan = PlaybackPlan(steps: [], frameRate: .fps20)
    private(set) var analysis: ClipAnalysis?
    private(set) var timings = PreviewTimings()
    /// How many times the full analysis has run for this open. It must stay at 1.
    private(set) var analyzeCount = 0
    /// How many times the playback plan was rebuilt (mode and rate changes).
    private(set) var planCount = 0
    /// Each time playback is restarted (a new plan), so the view can begin from the first step.
    private(set) var playbackStart = Date()

    var mode: PlaybackMode { didSet { if mode != oldValue { replan() } } }
    var frameRate: GifFrameRate { didSet { if frameRate != oldValue { replan() } } }

    @ObservationIgnored private let assetID: String
    @ObservationIgnored private var cache: StabilizedFrameCache?
    @ObservationIgnored private var frameTimes: [Double] = []
    @ObservationIgnored private var staged: StagedLivePhoto?
    @ObservationIgnored private let renderer = StabilizedRenderer()
    @ObservationIgnored private let context = CIContext()
    @ObservationIgnored private var openedAt = ContinuousClock.now
    @ObservationIgnored private var firstFrameReported = false

    init(assetID: String, defaults: ExportDefaults) {
        self.assetID = assetID
        mode = defaults.mode
        frameRate = defaults.gifFrameRate
    }

    // MARK: - Loading

    /// Extracts the files, analyzes the clip, builds the 720 px cache and starts playback. The
    /// extracted files are kept while the editor is open and removed by `close()`; on failure or
    /// cancellation they are removed here.
    func load() async {
        openedAt = ContinuousClock.now
        do {
            var timings = PreviewTimings()

            phase = .loading("Getting the photo from your library")
            let staging = try await StageTimer.time("stage") {
                try await PhotoKitLivePhotoLoader().load(assetID: assetID) { [weak self] fraction in
                    Task { @MainActor in self?.phase = .loading("Downloading from iCloud \(Int(fraction * 100))%") }
                }
            }
            staged = staging.value
            timings.record("stage", staging.milliseconds)

            phase = .loading("Reading the clip")
            let movieURL = staging.value.videoURL
            let imported = try await StageTimer.time("import") {
                try await LivePhotoImporter.describeClip(heicURL: staging.value.stillURL, movURL: movieURL)
            }
            timings.record("import", imported.milliseconds)
            let clip = imported.value
            frameTimes = clip.frameTimes.isEmpty
                ? (0..<clip.frameCount).map { Double($0) / max(clip.sourceFrameRate, 1) }
                : clip.frameTimes

            phase = .loading("Stabilizing")
            analyzeCount += 1
            // The app passes no residual-motion meter: it needs optical flow, which ships only in the
            // harness (decision 0001), so that signal is simply not measured here.
            let stageTimes = StageSink()
            let recordStage: @Sendable (String, Double) -> Void = { stage, ms in stageTimes.record(stage, ms) }
            let analyzed = try await ClipAnalyzer.analyze(
                movieURL: movieURL, referenceIndex: clip.referenceFrameIndex,
                estimator: VisionRegistrationEstimator(), residualMotion: nil,
                onStage: recordStage
            )
            for (stage, ms) in stageTimes.values { timings.record(stage, ms) }
            analysis = analyzed

            phase = .loading("Rendering the preview")
            let built = try await StageTimer.time("cache") {
                try await Self.buildCache(movieURL: movieURL, corrections: analyzed.path.corrections, sourceSize: analyzed.motion.size)
            }
            cache = built.value
            timings.record("cache", built.milliseconds)

            self.timings = timings
            replan()
            phase = .ready
        } catch is CancellationError {
            close()
        } catch {
            close()
            phase = .failed("\(error)")
        }
    }

    /// Off the main actor: decoding and rendering ~80 frames must not freeze the UI.
    private nonisolated static func buildCache(
        movieURL: URL, corrections: [simd_float3x3], sourceSize: CGSize
    ) async throws -> sending StabilizedFrameCache {
        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.noVideoTrack(movieURL)
        }
        let frames = try FrameSequence.make(asset: asset, track: track)
        return try StabilizedFrameCache.build(frames: frames, corrections: corrections, sourceSize: sourceSize, longEdge: 720)
    }

    /// Releases the cache and removes the extracted files. Safe to call more than once.
    func close() {
        cache = nil
        analysis = nil
        staged?.cleanup()
        staged = nil
    }

    // MARK: - Playback

    private func replan() {
        guard analysis != nil else { return }
        plan = PlaybackPlan.make(mode: mode, frameTimes: frameTimes, loop: analysis?.loop, frameRate: frameRate)
        planCount += 1
        playbackStart = Date()
    }

    /// The picture for one step: the cached stabilized frame, cropped to the solved crop, or, for
    /// the first frames of a loop, a blend of two cached frames. Reads the cache; renders nothing
    /// from source.
    func image(for step: PlaybackStep) -> CGImage? {
        guard let cache, let analysis else { return nil }
        let crop = analysis.path.crop
        if let secondary = step.secondary,
           let blended = try? renderer.blend(cache.frame(at: step.primary), cache.frame(at: secondary), weight: step.secondaryWeight)
        {
            let scaled = CGRect(
                x: crop.minX * cache.scale, y: crop.minY * cache.scale,
                width: crop.width * cache.scale, height: crop.height * cache.scale
            )
            let image = CIImage(cvPixelBuffer: blended).cropped(to: scaled)
            return context.createCGImage(image, from: image.extent)
        }
        let image = cache.image(at: step.primary, sourceRect: crop)
        return context.createCGImage(image, from: image.extent)
    }

    /// Called by the view when the first preview frame is on screen: the end of the preview-latency
    /// measurement, which is logged once.
    func firstFrameShown() {
        guard !firstFrameReported else { return }
        firstFrameReported = true
        let sinceOpen = ContinuousClock.now - openedAt
        let sinceOpenMs = Double(sinceOpen.components.seconds) * 1000 + Double(sinceOpen.components.attoseconds) / 1e15
        let measured = timings.total
        timings.record("firstFrame", max(0, sinceOpenMs - measured))
        StageTimer.logger.info("\(self.timings.summary, privacy: .public)")
    }

    // MARK: - What the view shows

    /// How the clip fared, as a RESULT. Never blocks anything: a failing clip still previews and
    /// is still editable (PRD R-18). The warning UI itself is #29.
    var stabilizationStatus: String {
        guard let analysis else { return "" }
        if !analysis.stabilized {
            return "Could not stabilize this clip" + (analysis.unstabilizedReason.map { ": \($0)" } ?? "") + ". Showing it as shot."
        }
        let crop = analysis.assessment.reading(for: .cropRetention).value ?? 0
        let failed = analysis.assessment.failedSignals.filter { $0 != .loopSeam } // the seam signal is under review (decision 0009)
        let base = "Stabilized, \(Int((crop * 100).rounded()))% of the frame kept"
        return failed.isEmpty ? base : base + ". Heads up: " + failed.map(\.rawValue).joined(separator: ", ") + " is outside its limit."
    }

    var hasLoop: Bool { analysis?.loop != nil }

    /// Width over height of the cropped picture, so the preview is the crop's own shape.
    var previewAspectRatio: CGFloat {
        guard let crop = analysis?.path.crop, crop.height > 0 else { return 4.0 / 3.0 }
        return crop.width / crop.height
    }
}

/// Collects stage timings that arrive from a closure the analysis calls.
private final class StageSink: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Double] = [:]
    func record(_ stage: String, _ ms: Double) { lock.withLock { storage[stage] = ms } }
    var values: [String: Double] { lock.withLock { storage } }
}
