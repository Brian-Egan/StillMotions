import Foundation

/// Where exports are written: a fresh folder for each, under the temporary directory.
///
/// The share sheet may keep reading a file until it is dismissed, so the app removes an export's folder
/// only after that (or at once, if the export is cancelled). A run that was killed leaves folders
/// behind; `purgeLeftovers` clears them at launch.
public struct ExportFolders: Sendable {
    public let root: URL

    public init(root: URL = FileManager.default.temporaryDirectory.appendingPathComponent("StillMotionsExports", isDirectory: true)) {
        self.root = root
    }

    public func makeFolder() throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    public func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    public func purgeLeftovers() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Folders currently on disk, for tests and the debug readout.
    public func folderCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).count
    }
}

public enum ExportJobError: Error, CustomStringConvertible {
    case notAllowed(String)

    public var description: String {
        switch self {
        case .notAllowed(let reason): return reason
        }
    }
}

/// Everything an export needs: the clip, the solved path, and the user's choices.
public struct ExportRequest: Sendable {
    public var movieURL: URL
    public var path: CameraPath
    public var loop: LoopSelection?
    public var format: ExportFormat
    public var preset: SizePreset
    public var mode: PlaybackMode
    public var gifRate: GifFrameRate
    /// How many frames the export will have (`ExportSizing.frameCount`), so progress can be a fraction.
    public var expectedFrameCount: Int

    public init(
        movieURL: URL, path: CameraPath, loop: LoopSelection?, format: ExportFormat, preset: SizePreset,
        mode: PlaybackMode, gifRate: GifFrameRate, expectedFrameCount: Int
    ) {
        self.movieURL = movieURL
        self.path = path
        self.loop = loop
        self.format = format
        self.preset = preset
        self.mode = mode
        self.gifRate = gifRate
        self.expectedFrameCount = expectedFrameCount
    }
}

public struct ExportedFile: Sendable {
    /// The folder holding the file; remove it (`ExportFolders.remove`) when the file is no longer needed.
    public let folder: URL
    public let url: URL
    public let bytes: Int
    public let width: Int
    public let height: Int
    public let frameCount: Int
    /// How long the export took, for the 10 s budget in PRD §1.3 (read off the phone in #35; a Mac
    /// number says nothing about it).
    public let milliseconds: Double
}

/// Runs one export to a fresh folder, reporting progress and cleaning up after itself.
///
/// If the export is cancelled or fails, the folder and anything partly written in it are removed
/// before the error is thrown, so a cancelled export leaves nothing behind (PRD R-12).
public enum ExportJob {
    public static func run(
        _ request: ExportRequest, folders: ExportFolders = ExportFolders(), progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ExportedFile {
        // Refuse before creating anything.
        if let reason = ExportMatrix.reason(format: request.format, mode: request.mode) { throw ExportJobError.notAllowed(reason) }

        let folder = try folders.makeFolder()
        let url = folder.appendingPathComponent(request.format == .gif ? "StillMotion.gif" : "StillMotion.mp4")
        let started = ContinuousClock.now
        let expected = Double(max(1, request.expectedFrameCount))
        let onFrame: @Sendable (Int) -> Void = { progress(min(1, Double($0) / expected)) }

        do {
            let width: Int, height: Int, frames: Int
            switch request.format {
            case .gif:
                let result = try await ClipExporter.exportGIF(
                    movieURL: request.movieURL, path: request.path, preset: request.preset, frameRate: request.gifRate,
                    mode: request.mode, loop: request.mode == .loop ? request.loop : nil, to: url, onFrame: onFrame
                )
                (width, height, frames) = (result.width, result.height, result.frameCount)
            case .mp4:
                let result = try await ClipExporter.exportVideo(
                    movieURL: request.movieURL, path: request.path, preset: request.preset, mode: request.mode, to: url, onFrame: onFrame
                )
                (width, height, frames) = (result.width, result.height, result.frameCount)
            }
            try Task.checkCancellation()
            progress(1)
            let elapsed = ContinuousClock.now - started
            return ExportedFile(
                folder: folder, url: url, bytes: (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0,
                width: width, height: height, frameCount: frames,
                milliseconds: Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            )
        } catch {
            folders.remove(folder)
            throw error
        }
    }
}
