import Foundation
import StillMotionsPipeline

/// One clip the harness will process.
struct ClipInput {
    let name: String
    let movieURL: URL
    /// Present for real Live Photos (HEIC + MOV pairs); synthetic fixtures have none.
    let stillURL: URL?
    /// Ground truth, present for synthetic fixtures.
    let truth: FixtureTruth?

    /// The reference frame: the Live Photo's key photo when there is a still, else the sidecar's
    /// reference, else the first frame.
    func referenceIndex() async throws -> Int {
        if let stillURL {
            return try await LivePhotoImporter.describeClip(heicURL: stillURL, movURL: movieURL).referenceFrameIndex
        }
        return truth?.referenceFrameIndex ?? 0
    }
}

enum ClipLocator {
    /// Every `<name>.mov` in `directory`, with its `<name>.heic` still and `<name>.truth.json`
    /// sidecar when they exist. Sorted by name so runs are reproducible.
    static func find(in directory: URL) throws -> [ClipInput] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let movies = names.filter { $0.lowercased().hasSuffix(".mov") }.sorted()
        return try movies.map { file in
            let stem = String(file.dropLast(4))
            let still = names.first { $0.lowercased() == "\(stem.lowercased()).heic" }
            let sidecar = directory.appendingPathComponent("\(stem).truth.json")
            return ClipInput(
                name: stem,
                movieURL: directory.appendingPathComponent(file),
                stillURL: still.map { directory.appendingPathComponent($0) },
                truth: FileManager.default.fileExists(atPath: sidecar.path) ? try FixtureTruth.load(from: sidecar) : nil
            )
        }
    }
}
