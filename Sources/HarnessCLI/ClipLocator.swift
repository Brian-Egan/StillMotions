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
    /// Every `<name>.mov` under `directory`, with its `<name>.heic` still and `<name>.truth.json`
    /// sidecar when they exist. Clips may sit directly in `directory` (the synthetic fixtures) or
    /// one folder down, one folder per Live Photo (a library export). Sorted by name so runs are
    /// reproducible.
    static func find(in directory: URL) throws -> [ClipInput] {
        var folders = [directory]
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let entry = directory.appendingPathComponent(name)
            // `fileExists(isDirectory:)` follows symlinks, which `resourceValues` does not.
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue {
                folders.append(entry)
            }
        }

        var clips: [ClipInput] = []
        for folder in folders {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            for file in names where file.lowercased().hasSuffix(".mov") {
                let stem = String(file.dropLast(4))
                let still = names.first { $0.lowercased() == "\(stem.lowercased()).heic" }
                let sidecar = folder.appendingPathComponent("\(stem).truth.json")
                clips.append(ClipInput(
                    name: stem,
                    movieURL: folder.appendingPathComponent(file),
                    stillURL: still.map { folder.appendingPathComponent($0) },
                    truth: FileManager.default.fileExists(atPath: sidecar.path) ? try FixtureTruth.load(from: sidecar) : nil
                ))
            }
        }
        return clips.sorted { $0.name < $1.name }
    }
}
