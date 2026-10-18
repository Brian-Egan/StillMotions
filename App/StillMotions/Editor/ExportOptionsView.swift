import StillMotionsPipeline
import SwiftUI

/// The export choices: format, size preset, and the estimated size of each (issue #32).
///
/// The GIF frame rate picker lives with the playback controls above, because it also sets how the
/// preview plays. Nothing here exports: that is #33. The rules (Loop is GIF-only) and the size
/// arithmetic are in the package, where `swift test` covers them; this view only shows them.
struct ExportOptionsView: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 10) {
            Text("Export").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            formatRow
            presetRow
            Text(sizeLine)
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier("estimatedSize")
            if model.exportFormat == .mp4 {
                Text("An MP4 keeps the clip's own frame rate. The GIF frame rate above only sets how this preview plays.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .accessibilityIdentifier("rateNote")
            }
        }
    }

    // MARK: - Format

    private var formatRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button { model.exportFormat = format } label: {
                        Text(Self.name(of: format)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChoiceButtonStyle(selected: model.exportFormat == format))
                    .disabled(model.unavailableReason(for: format) != nil)
                    .accessibilityIdentifier("format-\(format.rawValue)")
                    .accessibilityAddTraits(model.exportFormat == format ? .isSelected : [])
                }
            }
            // The reason is on screen, not only implied by a greyed-out button.
            if let reason = model.unavailableReason(for: .mp4) {
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("formatReason")
            }
        }
    }

    // MARK: - Size

    private var presetRow: some View {
        HStack(spacing: 8) {
            ForEach(SizePreset.allCases, id: \.self) { preset in
                Button { model.sizePreset = preset } label: {
                    VStack(spacing: 2) {
                        Text(Self.name(of: preset))
                        Text(estimate(at: preset)).font(.caption2).opacity(0.8)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(ChoiceButtonStyle(selected: model.sizePreset == preset))
                .accessibilityIdentifier("preset-\(preset.rawValue)")
                .accessibilityAddTraits(model.sizePreset == preset ? .isSelected : [])
            }
        }
    }

    private var sizeLine: String {
        "Estimated size: " + estimate(at: model.sizePreset) + " (give or take a quarter)"
    }

    private func estimate(at preset: SizePreset) -> String {
        guard let bytes = model.estimatedBytes(at: preset) else { return "…" }
        return "about " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func name(of format: ExportFormat) -> String {
        switch format {
        case .gif: return "GIF"
        case .mp4: return "MP4"
        }
    }

    private static func name(of preset: SizePreset) -> String {
        switch preset {
        case .small: return "Small \(SizePreset.small.longEdge ?? 0)"
        case .medium: return "Medium \(SizePreset.medium.longEdge ?? 0)"
        case .full: return "Full (native)"
        }
    }
}

/// A button that shows whether it is the current choice. One style for both states, so the type is
/// the same and a disabled button simply dims.
private struct ChoiceButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline)
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
            .foregroundStyle(selected ? Color.white : Color.accentColor)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor : Color.accentColor.opacity(0.12))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}
