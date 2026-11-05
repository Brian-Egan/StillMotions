import DropBox
import UIKit

/// The share extension: a DROP BOX and nothing more (PRD R-2, docs/decisions/0003-extension-strategy.md).
///
/// It copies the shared Live Photo's still and movie into the App Group container, writes a manifest, tells
/// the person to open StillMotions, and finishes. The app picks the files up the next time it opens
/// (issue #37).
///
/// Rules this class must not break (`scripts/check-extension-clean.sh` enforces the greppable ones):
///   - It links the `DropBox` module and nothing else of ours. The pipeline module (decode, stabilize,
///     encode) is not linked: the extension runs under an undocumented memory ceiling of about 120 MB that
///     is a high-water mark, and a file copy costs kilobytes, not megabytes.
///   - Files are copied from the URL the system hands over. The contents are never read into memory, and
///     the data-loading variant of the item provider call is never used.
///   - It does not try to open the containing app. That call is documented as supported only for Today and
///     iMessage extensions, and the usual responder-chain workaround fails on current iOS.
final class ShareViewController: UIViewController {
    private let spinner = UIActivityIndicatorView(style: .large)
    private let messageLabel = UILabel()
    private let doneButton = UIButton(type: .system)

    /// How long to wait for the system to hand over a file before giving up. A photo that lives only in
    /// iCloud is downloaded first, and that must not hang the share forever.
    private let fileTimeout: TimeInterval = 90

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        messageLabel.text = "Saving to StillMotions…"
        messageLabel.font = .preferredFont(forTextStyle: .title3)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.accessibilityIdentifier = "shareMessage"

        var configuration = UIButton.Configuration.filled()
        configuration.title = "Done"
        doneButton.configuration = configuration
        doneButton.isHidden = true
        doneButton.accessibilityIdentifier = "shareDone"
        doneButton.addAction(UIAction { [weak self] _ in self?.extensionContext?.completeRequest(returningItems: nil) }, for: .touchUpInside)

        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [spinner, messageLabel, doneButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])

        Task { await stageSharedPhoto() }
    }

    // MARK: - Staging

    private func stageSharedPhoto() async {
        do {
            try await stage()
            finish(DropBox.confirmationMessage)
        } catch let error as DropBoxError {
            finish(error.userMessage)
        } catch {
            finish(DropBoxError.cannotWrite(error.localizedDescription).userMessage)
        }
    }

    private func stage() async throws {
        guard let dropBox = DropBox() else { throw DropBoxError.noContainer }
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { throw DropBoxError.nothingShared }

        let plan = ShareSource.plan(attachments: providers.map(\.registeredTypeIdentifiers))
        if plan == .notALivePhoto { throw DropBoxError.notALivePhoto }

        let staging = try dropBox.begin()
        do {
            let stillFile: String, videoFile: String
            switch plan {
            case .bundle(let attachment, let typeIdentifier):
                (stillFile, videoFile) = try await copyOutOfBundle(providers[attachment], typeIdentifier, into: staging)
            case .pair(let still, let video):
                stillFile = try await copy(providers[still.attachment], still.typeIdentifier, as: .still, into: staging)
                videoFile = try await copy(providers[video.attachment], video.typeIdentifier, as: .video, into: staging)
            case .notALivePhoto:
                throw DropBoxError.notALivePhoto
            }
            _ = try staging.finish(stillFile: stillFile, videoFile: videoFile)
        } catch {
            staging.abort()
            throw error
        }
    }

    private func copy(_ provider: NSItemProvider, _ type: String, as role: DropBox.Role, into staging: DropBox.Staging) async throws -> String {
        try await withFile(from: provider, type: type) { url in try staging.copy(url, as: role) }
    }

    private func copyOutOfBundle(_ provider: NSItemProvider, _ type: String, into staging: DropBox.Staging) async throws -> (String, String) {
        try await withFile(from: provider, type: type) { bundle in
            // A Live Photo bundle is a folder holding the still and the movie.
            let contents = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
            guard let pair = ShareSource.stillAndVideo(in: contents) else { throw DropBoxError.notALivePhoto }
            return (try staging.copy(pair.still, as: .still), try staging.copy(pair.video, as: .video))
        }
    }

    /// Asks the system for a file and runs `work` on it, INSIDE the system's completion handler: the URL is
    /// only valid there, and is removed as soon as the handler returns. Gives up after `fileTimeout`, so a
    /// photo that is still downloading from iCloud cannot leave the share hanging.
    private func withFile<Result: Sendable>(
        from provider: NSItemProvider, type: String, _ work: @escaping @Sendable (URL) throws -> Result
    ) async throws -> Result {
        let gate = ResumeOnce()
        let timeout = fileTimeout
        return try await withCheckedThrowingContinuation { continuation in
            let progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                let outcome: Swift.Result<Result, Error>
                if let url {
                    outcome = Swift.Result { try work(url) }
                } else {
                    outcome = .failure(error ?? DropBoxError.emptyFile(type))
                }
                if gate.claim() { continuation.resume(with: outcome) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if gate.claim() {
                    progress.cancel()
                    continuation.resume(throwing: DropBoxError.timedOut)
                }
            }
        }
    }

    // MARK: - Showing the result

    private func finish(_ message: String) {
        spinner.stopAnimating()
        messageLabel.text = message
        doneButton.isHidden = false
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

/// Lets the first of two competing callbacks (the system finishing, or the timeout) win, and ignores the other.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
