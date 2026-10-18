import AVFoundation
import CoreImage
import Observation
import Photos
import StillMotionsPipeline
import os

/// The editor's state: it opens a Live Photo, solves it ONCE into a stabilized frame cache, and
/// then plays that cache in the chosen mode at the chosen rate (ARCHITECTURE §5).
///
/// Changing the playback mode or the frame rate only re-plans which cached frames play in which
/// order (`PlaybackPlan`), so it is instant and never solves again.
///
/// Changing the STABILIZATION (Off, Smooth, Locked) solves a new path from the motion already
/// estimated, re-selects the loop and rebuilds the cache. It never estimates motion again, and the
/// preview that is playing keeps playing until the new one is ready (PRD R-7a, R-15).
/// `estimateCount` and `analyzeCount` count those two steps; the UI tests hold `estimateCount` at 1.
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
    /// How many times motion was estimated for this open. It must stay at 1, whatever is switched.
    private(set) var estimateCount = 0
    /// How many times a path was solved (and the loop re-selected): once on open, then once per
    /// stabilization change.
    private(set) var analyzeCount = 0
    /// The stabilization the preview is showing.
    private(set) var stabilization: StabilizationMode = .default
    /// The stabilization the user last asked for. Differs from `stabilization` only while a
    /// switch is being solved.
    private(set) var requestedStabilization: StabilizationMode = .default
    /// How much of the frame each stabilization keeps for this clip, shown next to the control.
    private(set) var cropByStabilization: [StabilizationMode: Double] = [:]
    /// How many times the playback plan was rebuilt (mode and rate changes).
    private(set) var planCount = 0
    /// Each time playback is restarted (a new plan), so the view can begin from the first step.
    private(set) var playbackStart = Date()

    /// What the clip looks like to a GIF encoder, measured once from the preview frames. It is what
    /// lets the size estimate tell a plain wall from leaves in the wind (issue #31).
    private(set) var content: ContentFeatures?

    var mode: PlaybackMode {
        didSet {
            guard mode != oldValue else { return }
            // Loop is GIF-only (PRD R-10): choosing it while MP4 is selected moves to GIF.
            exportFormat = ExportMatrix.format(exportFormat, afterSelecting: mode)
            replan()
        }
    }
    var frameRate: GifFrameRate { didSet { if frameRate != oldValue { replan() } } }
    /// The export choices (issue #32). Nothing exports from here; the export itself is #33.
    var exportFormat: ExportFormat
    var sizePreset: SizePreset

    @ObservationIgnored private let assetID: String
    @ObservationIgnored private var cache: StabilizedFrameCache?
    @ObservationIgnored private var frameTimes: [Double] = []
    @ObservationIgnored private var staged: StagedLivePhoto?
    @ObservationIgnored private var motion: ClipAnalyzer.MotionResult?
    @ObservationIgnored private var movieURL: URL?
    @ObservationIgnored private var switchTask: Task<Void, Never>?
    @ObservationIgnored private let renderer = StabilizedRenderer()
    @ObservationIgnored private let context = CIContext()
    @ObservationIgnored private var openedAt = ContinuousClock.now
    @ObservationIgnored private var firstFrameReported = false

    init(assetID: String, defaults: ExportDefaults) {
        self.assetID = assetID
        mode = defaults.mode
        frameRate = defaults.gifFrameRate
        exportFormat = ExportMatrix.format(defaults.format, afterSelecting: defaults.mode)
        sizePreset = defaults.sizePreset
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
            // The app passes no residual-motion meter: it needs optical flow, which ships only in the
            // harness (decision 0001), so that signal is simply not measured here.
            estimateCount += 1
            let estimated = try await StageTimer.time("estimate") {
                try await ClipAnalyzer.estimateMotion(
                    movieURL: movieURL, referenceIndex: clip.referenceFrameIndex, estimator: VisionRegistrationEstimator()
                )
            }
            timings.record("estimate", estimated.milliseconds)
            motion = estimated.value
            self.movieURL = movieURL
            cropByStabilization = ClipAnalyzer.cropRetentions(motion: estimated.value)

            let solved = try await solve(stabilization, movieURL: movieURL, motion: estimated.value)
            for (stage, ms) in solved.stageTimes { timings.record(stage, ms) }
            analysis = solved.analysis

            phase = .loading("Rendering the preview")
            let built = try await StageTimer.time("cache") {
                try await Self.buildCache(
                    movieURL: movieURL, corrections: solved.analysis.path.corrections,
                    sourceSize: solved.analysis.motion.size, crop: solved.analysis.path.crop
                )
            }
            cache = built.value.cache
            content = built.value.content
            // The cache stage includes measuring the content; report the two apart.
            timings.record("cache", max(0, built.milliseconds - built.value.contentMilliseconds))
            timings.record("content", built.value.contentMilliseconds)

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

    /// Solves the path for `mode` from motion that is already estimated, and picks the loop. This
    /// is the whole cost of a stabilization change apart from rebuilding the cache.
    private func solve(
        _ mode: StabilizationMode, movieURL: URL, motion: ClipAnalyzer.MotionResult
    ) async throws -> (analysis: ClipAnalysis, stageTimes: [String: Double]) {
        analyzeCount += 1
        let stageTimes = StageSink()
        let recordStage: @Sendable (String, Double) -> Void = { stage, ms in stageTimes.record(stage, ms) }
        let analyzed = try await ClipAnalyzer.analyze(movieURL: movieURL, motion: motion, mode: mode, onStage: recordStage)
        return (analyzed, stageTimes.values)
    }

    // MARK: - Stabilization

    /// Switches to another stabilization. Latest request wins: asking again while one is being
    /// solved abandons the earlier one. The preview that is playing keeps playing until the new
    /// cache is ready, then everything swaps at once.
    func selectStabilization(_ mode: StabilizationMode) {
        guard phase == .ready, mode != requestedStabilization else { return }
        requestedStabilization = mode
        switchTask?.cancel()
        switchTask = Task { await applyStabilization(mode) }
    }

    private func applyStabilization(_ mode: StabilizationMode) async {
        guard let movieURL, let motion else { return }
        let started = ContinuousClock.now
        do {
            let solved = try await solve(mode, movieURL: movieURL, motion: motion)
            let built = try await Self.buildCache(
                movieURL: movieURL, corrections: solved.analysis.path.corrections,
                sourceSize: solved.analysis.motion.size, crop: solved.analysis.path.crop
            )
            // A newer request, or closing the editor, makes this result stale.
            guard !Task.isCancelled, requestedStabilization == mode, self.motion != nil else { return }
            cache = built.cache
            content = built.content
            analysis = solved.analysis
            stabilization = mode
            replan()
            let elapsed = ContinuousClock.now - started
            let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            StageTimer.logger.info("stabilization switch to \(mode.rawValue, privacy: .public): \(ms, format: .fixed(precision: 0)) ms")
        } catch {
            // Keep what is playing; offer the previous choice again.
            if requestedStabilization == mode { requestedStabilization = stabilization }
            StageTimer.logger.error("stabilization switch to \(mode.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Off the main actor: decoding and rendering ~80 frames must not freeze the UI.
    private nonisolated static func buildCache(
        movieURL: URL, corrections: [simd_float3x3], sourceSize: CGSize, crop: CGRect
    ) async throws -> sending BuiltPreview {
        let asset = AVURLAsset(url: movieURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipImportError.noVideoTrack(movieURL)
        }
        let frames = try FrameSequence.make(asset: asset, track: track)
        let cache = try StabilizedFrameCache.build(frames: frames, corrections: corrections, sourceSize: sourceSize, longEdge: 720)
        // Measured here, off the main actor, from frames already in memory: a few small images.
        let start = ContinuousClock.now
        let content = cache.contentFeatures(crop: crop)
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return BuiltPreview(cache: cache, content: content, contentMilliseconds: ms)
    }

    /// A rendered preview cache and the content measured from it.
    private struct BuiltPreview {
        let cache: StabilizedFrameCache
        let content: ContentFeatures?
        let contentMilliseconds: Double
    }

    /// Releases the cache and removes the extracted files. Safe to call more than once.
    func close() {
        exporter.cancel()
        switchTask?.cancel()
        switchTask = nil
        motion = nil
        cache = nil
        content = nil
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
        if stabilization == .off { return "Shown as shot: the whole frame, no stabilization." }
        if !analysis.stabilized {
            return "Could not stabilize this clip" + (analysis.unstabilizedReason.map { ": \($0)" } ?? "") + ". Showing it as shot."
        }
        let crop = analysis.assessment.reading(for: .cropRetention).value ?? 0
        let failed = analysis.assessment.failedSignals.filter { $0 != .loopSeam } // the seam signal is under review (decision 0009)
        let base = "Stabilized, \(Int((crop * 100).rounded()))% of the frame kept"
        return failed.isEmpty ? base : base + ". Heads up: " + failed.map(\.rawValue).joined(separator: ", ") + " is outside its limit."
    }

    var hasLoop: Bool { analysis?.loop != nil }

    // MARK: - Export choices (issue #32)

    /// Estimated size, in bytes, of exporting with the current choices at `preset`. Pure arithmetic
    /// over numbers already in memory, so the screen can show all three presets on every change.
    /// Nil until the clip is open.
    func estimatedBytes(at preset: SizePreset) -> Int? {
        guard let analysis else { return nil }
        return ExportSizing.estimate(
            format: exportFormat, preset: preset, mode: mode, gifRate: frameRate, path: analysis.path,
            frameTimes: frameTimes, loop: analysis.loop, sourceFrameRate: analysis.motion.frameRate, content: content
        )
    }

    /// The export controller; it lives with the editor so leaving the editor can stop an export.
    @ObservationIgnored let exporter = ExportController()

    /// What an export would do with the current choices, or nil until the clip is open.
    func exportRequest() -> ExportRequest? {
        guard let analysis, let movieURL else { return nil }
        return ExportRequest(
            movieURL: movieURL, path: analysis.path, loop: analysis.loop, format: exportFormat, preset: sizePreset,
            mode: mode, gifRate: frameRate,
            expectedFrameCount: ExportSizing.frameCount(
                format: exportFormat, mode: mode, gifRate: frameRate, frameTimes: frameTimes, loop: analysis.loop
            )
        )
    }

    /// Why `format` cannot be chosen with the current playback mode, or nil when it can.
    func unavailableReason(for format: ExportFormat) -> String? {
        ExportMatrix.reason(format: format, mode: mode)
    }

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
