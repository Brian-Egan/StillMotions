import Foundation
import os

/// Where the time goes between tapping a photo and seeing it move, so the 2.0 s preview budget
/// (PRD §1.3) can be read off a device WITHOUT changing code.
///
/// Two ways to read it, both always on:
/// - **Instruments**: every stage is a signpost interval (subsystem `com.began.Still-Motions`,
///   category `preview`), so the Points of Interest / os_signpost track shows them.
/// - **The log**: one line per open, e.g. `preview ready in 1840 ms: stage 60, import 90, ...`
///   (Console.app, or `log stream --predicate 'subsystem == "com.began.Still-Motions"'`).
///
/// Stages, in order: `stage` (extract the files from the library), `import` (read the clip's
/// frame times), `estimate` (decode and register every frame; decode is inside this), `solve`,
/// `loopSelection` (decodes and renders again to compare frames), `cache` (decode and render the
/// 720 px stabilized frames), `firstFrame` (until the first preview frame is on screen).
struct PreviewTimings: Equatable {
    static let stageOrder = ["stage", "import", "estimate", "solve", "loopSelection", "cache", "firstFrame"]

    private(set) var milliseconds: [String: Double] = [:]

    mutating func record(_ stage: String, _ ms: Double) {
        milliseconds[stage] = ms
    }

    /// Everything from tapping the photo to the first frame on screen.
    var total: Double { milliseconds.values.reduce(0, +) }

    var summary: String {
        let parts = Self.stageOrder.compactMap { stage in milliseconds[stage].map { "\(stage) \(Int($0.rounded()))" } }
        return "preview ready in \(Int(total.rounded())) ms: " + parts.joined(separator: ", ")
    }
}

/// Times stages and reports each to both the signposter and a collector.
struct StageTimer {
    static let signposter = OSSignposter(subsystem: "com.began.Still-Motions", category: "preview")
    static let logger = Logger(subsystem: "com.began.Still-Motions", category: "preview")

    /// Runs `work`, wrapped in a signpost interval named `stage`, and returns its result with the
    /// elapsed milliseconds.
    @MainActor
    static func time<T>(_ stage: StaticString, _ work: () async throws -> T) async rethrows -> (value: T, milliseconds: Double) {
        let state = signposter.beginInterval(stage)
        let start = ContinuousClock.now
        defer { signposter.endInterval(stage, state) }
        let value = try await work()
        let elapsed = ContinuousClock.now - start
        return (value, Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
    }
}
