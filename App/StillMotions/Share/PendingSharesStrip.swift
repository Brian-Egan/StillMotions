import ImageIO
import SwiftUI

/// The photos shared to StillMotions that are waiting to be opened, above the gallery, newest first. Shown
/// whether or not the library itself can be read: a shared photo needs no library access.
struct PendingSharesStrip: View {
    @Environment(PendingShares.self) private var pending

    var body: some View {
        if !pending.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shared with StillMotions")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(pending.items) { item in
                            NavigationLink(value: Route.shared(id: item.id)) {
                                SharedThumbnail(url: item.stillURL)
                                    .frame(width: 84, height: 84)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Shared photo from \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .accessibilityIdentifier("pendingShare")
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical, 8)
            .accessibilityIdentifier("pendingSharesStrip")
        }
    }
}

/// A small picture of the shared still, read straight from its file at thumbnail size (never the whole image).
private struct SharedThumbnail: View {
    let url: URL
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.2)
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFill() }
        }
        .task(id: url) {
            image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 252,
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
        }
    }
}
