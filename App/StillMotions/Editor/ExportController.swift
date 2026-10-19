import Foundation
import Observation
import Photos
import StillMotionsPipeline
import UniformTypeIdentifiers
import os

/// Runs one export at a time and gets the file to its destination (issue #33).
///
/// Nothing exports until the user taps Share or Save to Photos (PRD R-12). The encoding, the
/// progress, the refusal of Loop as MP4 and the cleanup of a cancelled export are in the package's
/// `ExportJob`, where `swift test` covers them; this class only drives them and talks to the system.
@MainActor
@Observable
final class ExportController {
    enum Destination { case share, photos }

    enum State: Equatable {
        case idle
        case exporting(Double)
        case saving
        case saved
        case failed(String)
    }

    private(set) var state: State = .idle
    /// The finished file while the share sheet is up. Its folder is removed only after the sheet is
    /// dismissed, because the share sheet may keep reading the file until then.
    var shareFile: ExportedFile?

    @ObservationIgnored private let folders = ExportFolders()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private static let logger = Logger(subsystem: "com.began.Still-Motions", category: "export")

    var isBusy: Bool {
        switch state {
        case .exporting, .saving: return true
        case .idle, .saved, .failed: return false
        }
    }

    /// Export folders on disk right now. The debug readout shows it; it must be 0 at rest.
    var folderCount: Int { folders.folderCount() }

    func start(_ request: ExportRequest, to destination: Destination) {
        guard !isBusy else { return }
        state = .exporting(0)
        task = Task { [folders] in
            do {
                let file = try await ExportJob.run(request, folders: folders) { fraction in
                    Task { @MainActor [weak self] in
                        if case .exporting = self?.state { self?.state = .exporting(fraction) }
                    }
                }
                Self.logger.info("export finished in \(file.milliseconds, format: .fixed(precision: 0)) ms: \(request.format.rawValue, privacy: .public) \(request.preset.rawValue, privacy: .public), \(file.frameCount) frames, \(file.width)x\(file.height), \(file.bytes) bytes")
                try Task.checkCancellation()
                switch destination {
                case .share:
                    shareFile = file
                    state = .idle
                case .photos:
                    state = .saving
                    defer { folders.remove(file.folder) }
                    try await PhotoLibrarySaver.save(fileURL: file.url, format: request.format)
                    state = .saved
                }
            } catch is CancellationError {
                state = .idle
            } catch {
                Self.logger.error("export failed: \(String(describing: error), privacy: .public)")
                state = .failed(Self.message(for: error))
            }
        }
    }

    /// Stops the export. The job removes its own partial file before it throws.
    func cancel() {
        task?.cancel()
        task = nil
        if case .exporting = state { state = .idle }
    }

    /// The share sheet was dismissed: only now is the file no longer needed.
    func shareFinished() {
        if let file = shareFile { folders.remove(file.folder) }
        shareFile = nil
    }

    func dismissStatus() {
        if case .saved = state { state = .idle }
        if case .failed = state { state = .idle }
    }

    private static func message(for error: Error) -> String {
        if let saveError = error as? PhotoLibrarySaver.SaveError { return saveError.description }
        return "The export failed: \(error)"
    }
}

/// Adds an exported file to the photo library, asking only for permission to ADD (PRD R-12): the app
/// never needs to read what else is there for this.
enum PhotoLibrarySaver {
    enum SaveError: Error, CustomStringConvertible {
        case notAllowed
        var description: String { "StillMotions isn't allowed to save to Photos. You can change that in Settings." }
    }

    static func save(fileURL: URL, format: ExportFormat) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            // Photos copies the file; the app removes its own copy afterwards.
            options.shouldMoveFile = false
            if format == .gif { options.uniformTypeIdentifier = UTType.gif.identifier }
            PHAssetCreationRequest.forAsset().addResource(with: format == .gif ? .photo : .video, fileURL: fileURL, options: options)
        }
    }
}
