import Foundation

// Getting a Live Photo's two files out of a photo library and onto disk, without knowing anything
// about PhotoKit. The app adapts PhotoKit to these types (PRD R-4, R-24); everything that can go
// wrong in the logic (which files, never mixing generations, cleanup) lives here, where
// `swift test` and CI reach it.

/// The kinds of resource a library asset can hold. The app maps PhotoKit's `PHAssetResourceType`
/// onto these.
public enum LivePhotoResourceKind: String, Sendable, Equatable {
    case photo
    case pairedVideo
    case fullSizePhoto
    case fullSizePairedVideo
    /// Anything else an asset carries (adjustment data, an alternate photo, and so on).
    case other
}

public struct LivePhotoResource: Sendable, Equatable {
    public let kind: LivePhotoResourceKind
    /// The library's file name for it, used only to keep a sensible extension.
    public let filename: String

    public init(kind: LivePhotoResourceKind, filename: String) {
        self.kind = kind
        self.filename = filename
    }
}

/// Which generation of a Live Photo's files to use.
public enum LivePhotoTier: String, Sendable, Equatable {
    /// `.photo` + `.pairedVideo`: what the camera wrote.
    case original
    /// `.fullSizePhoto` + `.fullSizePairedVideo`: the files after the user edited the Live Photo.
    case edited
}

/// The still and the video to extract, chosen together.
public struct LivePhotoPlan: Sendable, Equatable {
    public let tier: LivePhotoTier
    public let still: LivePhotoResource
    public let video: LivePhotoResource
}

public enum LivePhotoStagingError: Error, CustomStringConvertible, Equatable {
    /// The asset has no paired video at all: it is a plain still, not a Live Photo.
    case notALivePhoto
    /// The asset looks like a Live Photo but one half of every pair is missing.
    case incompleteResources(String)
    /// The library did not give up the file (iCloud unreachable, for example).
    case writeFailed(resource: String, reason: String)
    /// The library reported success but left no file, or an empty one.
    case emptyFile(resource: String)

    public var description: String {
        switch self {
        case .notALivePhoto:
            return "this item is not a Live Photo: it has no paired video"
        case .incompleteResources(let detail):
            return "the Live Photo's files are incomplete: \(detail)"
        case .writeFailed(let resource, let reason):
            return "could not get the \(resource) from the photo library: \(reason)"
        case .emptyFile(let resource):
            return "the photo library produced an empty \(resource) file"
        }
    }
}

/// Decides which still and video to extract, and never mixes generations.
///
/// An edited Live Photo holds two complete pairs, and a still from one pair does not correspond to
/// the video of the other (different crop, different frames), so the pair is chosen as a unit:
///
/// 1. **Edited**, if both full-size resources exist: the edits are what the user sees.
/// 2. **Original**, if both original resources exist: used when nothing was edited, and also when
///    only one full-size half exists (a half-finished edit), because a consistent original pair is
///    better than a mismatched one. The edits are not applied in that case.
/// 3. Otherwise a descriptive error, never a guess.
public enum LivePhotoResourcePlanner {
    public static func plan(resources: [LivePhotoResource]) throws -> LivePhotoPlan {
        func first(_ kind: LivePhotoResourceKind) -> LivePhotoResource? { resources.first { $0.kind == kind } }

        if let still = first(.fullSizePhoto), let video = first(.fullSizePairedVideo) {
            return LivePhotoPlan(tier: .edited, still: still, video: video)
        }
        if let still = first(.photo), let video = first(.pairedVideo) {
            return LivePhotoPlan(tier: .original, still: still, video: video)
        }

        let hasAnyVideo = first(.pairedVideo) != nil || first(.fullSizePairedVideo) != nil
        guard hasAnyVideo else { throw LivePhotoStagingError.notALivePhoto }

        let present = resources.map(\.kind.rawValue).sorted().joined(separator: ", ")
        throw LivePhotoStagingError.incompleteResources(
            "it has a paired video but no matching still (found: \(present.isEmpty ? "nothing" : present))"
        )
    }
}

/// Writes one resource to a file. The app passes PhotoKit's `PHAssetResourceManager` here; tests
/// pass a stub. `progress` is 0...1, may be called from any thread, and may be kept and called later
/// (an iCloud download reports it as the bytes arrive).
public typealias LivePhotoResourceWriter = @Sendable (
    _ resource: LivePhotoResource,
    _ destination: URL,
    _ progress: @escaping @Sendable (Double) -> Void
) async throws -> Void

/// A Live Photo's files in a temporary folder, ready for `LivePhotoImporter`.
public struct StagedLivePhoto: Sendable {
    public let directory: URL
    public let stillURL: URL
    public let videoURL: URL
    public let plan: LivePhotoPlan

    /// Removes the folder. Call it when processing is done; the stager already removes it on any
    /// error, so only a successful stage needs this.
    public func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Extracts a Live Photo's still and video into a fresh temporary folder.
public struct LivePhotoStager: Sendable {
    /// Every staged photo lives in its own folder under here.
    public let root: URL

    public init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("StillMotionsStaging", isDirectory: true)) {
        self.root = root
    }

    /// Plans, then writes the still and the video into a new folder.
    ///
    /// On ANY failure, including cancellation, the folder is removed before the error is thrown,
    /// so a failed or cancelled load leaves nothing behind. `progress` runs 0...1 across both files
    /// (each counts for half), and never goes backwards.
    public func stage(
        resources: [LivePhotoResource],
        writer: LivePhotoResourceWriter,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> StagedLivePhoto {
        let plan = try LivePhotoResourcePlanner.plan(resources: resources)
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let still = directory.appendingPathComponent("still").appendingPathExtension(Self.fileExtension(of: plan.still, fallback: "heic"))
        let video = directory.appendingPathComponent("video").appendingPathExtension(Self.fileExtension(of: plan.video, fallback: "mov"))
        let tracker = MonotonicProgress(report: progress)

        do {
            for (index, (resource, destination)) in [(plan.still, still), (plan.video, video)].enumerated() {
                try Task.checkCancellation()
                do {
                    try await writer(resource, destination) { fraction in
                        tracker.report((Double(index) + min(max(fraction, 0), 1)) / 2)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as LivePhotoStagingError {
                    throw error
                } catch {
                    throw LivePhotoStagingError.writeFailed(resource: Self.name(of: resource), reason: "\(error)")
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
                guard size > 0 else { throw LivePhotoStagingError.emptyFile(resource: Self.name(of: resource)) }
            }
            tracker.report(1)
            return StagedLivePhoto(directory: directory, stillURL: still, videoURL: video, plan: plan)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Removes every folder under `root`: what an earlier run left behind if it was killed
    /// mid-load. Call it at launch, before anything is staged.
    public func purgeLeftovers() {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in contents { try? FileManager.default.removeItem(at: item) }
    }

    /// How many staged folders currently exist.
    public func stagedFolderCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).count) ?? 0
    }

    public static func fileExtension(of resource: LivePhotoResource, fallback: String) -> String {
        let ext = (resource.filename as NSString).pathExtension.lowercased()
        let safe = ext.allSatisfy { $0.isLetter || $0.isNumber }
        return ext.isEmpty || !safe ? fallback : ext
    }

    static func name(of resource: LivePhotoResource) -> String {
        switch resource.kind {
        case .photo, .fullSizePhoto: return "still"
        case .pairedVideo, .fullSizePairedVideo: return "video"
        case .other: return "resource"
        }
    }
}

/// Reports progress that only ever moves forward: a download that restarts or a callback that
/// arrives late must not make a progress bar jump back.
private final class MonotonicProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var highest = 0.0
    private let onReport: (@Sendable (Double) -> Void)?

    init(report: (@Sendable (Double) -> Void)?) {
        onReport = report
    }

    func report(_ value: Double) {
        let advanced: Double? = lock.withLock {
            guard value > highest else { return nil }
            highest = value
            return value
        }
        if let advanced { onReport?(advanced) }
    }
}
