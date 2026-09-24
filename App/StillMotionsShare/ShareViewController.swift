import UIKit

/// Scaffolding only. Referenced by `NSExtensionPrincipalClass` in project.yml so the
/// extension target builds; currently completes immediately without doing anything.
///
/// The real implementation is a DROP BOX and nothing more (PRD R-2,
/// docs/decisions/0003-extension-strategy.md):
///
///   1. Copy the paired HEIC and MOV into the App Group container using
///      `loadFileRepresentation` — never `loadDataRepresentation`, never `Data` in memory,
///      never UserDefaults as a transport.
///   2. Write a JSON manifest with a UUID, timestamp, and the staged filenames.
///   3. Show a confirmation that tells the user to open StillMotions.
///   4. `completeRequest(returningItems:)`.
///
/// Rules this class must not break:
///   - Do NOT import StillMotionsPipeline. If it ever does, the drop-box decision has been
///     violated. No decoding, no stabilization, no encoding here.
///   - Do NOT attempt to launch the containing app. `NSExtensionContext.open(_:)` is
///     documented as supported only for Today and iMessage extensions, and the
///     responder-chain `openURL` hack fails on current iOS.
///   - Peak memory must stay under 100 MB against an undocumented ~120 MB jetsam limit
///     that is a high-water mark, not an average (PRD §1.3).
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        extensionContext?.completeRequest(returningItems: nil)
    }
}
