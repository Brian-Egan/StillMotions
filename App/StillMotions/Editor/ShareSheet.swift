import SwiftUI
import UIKit

/// The system share sheet for one file. The only UIKit in the editor: SwiftUI's `ShareLink` needs the
/// file up front, but here the file is made after the tap.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    /// Called when the sheet goes away, whether or not anything was shared.
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
