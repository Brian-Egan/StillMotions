import Foundation

/// The hand-off between the share extension and the app (issue #36, decision 0003).
///
/// The extension cannot launch the app and cannot afford to process anything, so it only COPIES: the
/// photo and its video go into the shared App Group container, with a small manifest saying what they
/// are. The app picks them up the next time it opens (issue #37).
///
/// This module is deliberately tiny and depends on nothing but Foundation. It is the only code the
/// extension and the app share, so the folder layout and the manifest cannot drift apart, and the
/// extension does not need to link the pipeline (which would put the encoder in a process with an
/// undocumented ~120 MB ceiling).
///
/// Layout, under the container's `DropBox` folder, one folder per share:
///
///     <uuid>/still.heic
///     <uuid>/video.mov
///     <uuid>/manifest.json      written LAST
///
/// The manifest is written last and atomically, so a folder either has a complete manifest and both
/// files, or no manifest. A run killed part-way leaves a folder with no manifest, which the app can tell
/// from a finished share and clear.
public struct DropBox: Sendable {
    public static let appGroup = "group.com.began.Still-Motions"
    public static let manifestFileName = "manifest.json"

    /// The folder every share lives under.
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// The App Group's `DropBox` folder, or nil when the container is not available (the app group
    /// entitlement is missing).
    public init?(appGroup: String = DropBox.appGroup, fileManager: FileManager = .default) {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
        self.root = container.appendingPathComponent("DropBox", isDirectory: true)
    }

    public func folder(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // MARK: - Writing (the extension)

    /// Starts a share: makes its folder. Nothing is visible to the app as a finished share until `finish`.
    public func begin(id: UUID = UUID()) throws -> Staging {
        let folder = folder(for: id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw DropBoxError.cannotWrite(error.localizedDescription)
        }
        return Staging(id: id, folder: folder)
    }

    /// One share being written.
    public struct Staging: Sendable {
        public let id: UUID
        public let folder: URL

        /// Copies `source` into the share's folder as `still` or `video` with the source's own file
        /// extension, and returns the name it was given. A filesystem copy: the file's contents are never
        /// read into memory, so a long video costs kilobytes of memory, not megabytes.
        public func copy(_ source: URL, as role: Role) throws -> String {
            let name = role.fileName(extension: source.pathExtension)
            let destination = folder.appendingPathComponent(name)
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: source, to: destination)
                let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
                guard size > 0 else { throw DropBoxError.emptyFile(name) }
            } catch let error as DropBoxError {
                throw error
            } catch {
                throw DropBoxError.cannotWrite(error.localizedDescription)
            }
            return name
        }

        /// Writes the manifest, which is what makes the share complete. Call it only after both files
        /// have been copied.
        public func finish(stillFile: String, videoFile: String, now: Date = Date()) throws -> Manifest {
            // The manifest stores its time to the second, so use whole seconds from the start: what this
            // returns is then exactly what the app reads back.
            let created = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            let manifest = Manifest(id: id, createdAt: created, stillFile: stillFile, videoFile: videoFile)
            do {
                try Self.encoder.encode(manifest).write(to: folder.appendingPathComponent(DropBox.manifestFileName), options: .atomic)
            } catch {
                throw DropBoxError.cannotWrite(error.localizedDescription)
            }
            return manifest
        }

        /// Removes a share that did not finish, files and all.
        public func abort() {
            try? FileManager.default.removeItem(at: folder)
        }

        static var encoder: JSONEncoder {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return encoder
        }
    }

    public enum Role: Sendable {
        case still, video

        func fileName(extension fileExtension: String) -> String {
            let base = self == .still ? "still" : "video"
            let cleaned = fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
            return cleaned.isEmpty ? base : "\(base).\(cleaned)"
        }
    }

    // MARK: - The manifest

    /// What a finished share says about itself. `version` lets a future build change the format without
    /// misreading an old one (an unknown version is treated as unreadable, not guessed at).
    public struct Manifest: Codable, Equatable, Sendable {
        public static let currentVersion = 1

        public var version: Int
        public var id: UUID
        public var createdAt: Date
        /// File names inside the share's folder.
        public var stillFile: String
        public var videoFile: String

        public init(id: UUID, createdAt: Date, stillFile: String, videoFile: String, version: Int = Manifest.currentVersion) {
            self.version = version
            self.id = id
            self.createdAt = createdAt
            self.stillFile = stillFile
            self.videoFile = videoFile
        }
    }

    // MARK: - Reading (the app, issue #37)

    /// The finished shares, oldest first. A folder with no manifest, an unreadable one, or one naming
    /// files that are not there is not returned: those are for `unfinishedFolders`.
    public func finishedShares() -> [Manifest] {
        subfolders().compactMap { readManifest(in: $0) }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Folders that are not a usable finished share: no manifest (a share killed part-way), a manifest that
    /// cannot be read, or one whose files are missing. The app clears these, with their files.
    public func unfinishedFolders() -> [URL] {
        subfolders().filter { readManifest(in: $0) == nil }
    }

    public func stillURL(of manifest: Manifest) -> URL { folder(for: manifest.id).appendingPathComponent(manifest.stillFile) }
    public func videoURL(of manifest: Manifest) -> URL { folder(for: manifest.id).appendingPathComponent(manifest.videoFile) }

    /// Removes a share's folder and everything in it.
    public func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    private func subfolders() -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private func readManifest(in folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(DropBox.manifestFileName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(Manifest.self, from: data),
              manifest.version == Manifest.currentVersion,
              folder.lastPathComponent == manifest.id.uuidString,
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(manifest.stillFile).path),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent(manifest.videoFile).path)
        else { return nil }
        return manifest
    }
}

/// Why a share did not work, in words the person sharing can act on.
public enum DropBoxError: Error, Equatable, CustomStringConvertible, Sendable {
    case noContainer
    case notALivePhoto
    case timedOut
    case cannotWrite(String)
    case emptyFile(String)
    case nothingShared

    public var description: String { userMessage }

    public var userMessage: String {
        switch self {
        case .noContainer:
            return "StillMotions couldn't reach its storage. Open StillMotions once, then try sharing again."
        case .notALivePhoto:
            return "That's a regular photo, not a Live Photo. Pick a photo with the Live badge and share it again."
        case .timedOut:
            return "The photo is still downloading from iCloud. Open it in Photos until it finishes, then share it again."
        case .cannotWrite:
            return "StillMotions couldn't save the photo. Check that your phone has free space, then try again."
        case .emptyFile:
            return "The photo came through empty. Try sharing it again."
        case .nothingShared:
            return "Nothing was shared. Choose a Live Photo and share it again."
        }
    }
}

extension DropBox {
    /// What the person sees once a share is safely staged. The sentence matters: the extension cannot open
    /// the app, so without it the share looks like it silently did nothing (decision 0003).
    public static let confirmationMessage = "Saved. Open StillMotions to edit it."
}
