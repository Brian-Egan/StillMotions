import StillMotionsPipeline
import SwiftUI

/// The defaults the editor and export screen start from (PRD R-19), including the pixel sizes of the
/// Small and Medium presets. Quality thresholds are deliberately NOT here: they live in the PRD, and
/// changing one needs a decision record because the harness baseline depends on it.
///
/// What is stored, validated and restored lives in the package (`ExportDefaultsStore`, `PresetSizes`),
/// where `swift test` covers it. Changes apply the next time a photo is opened.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    /// What is typed in the two size fields, kept as text until it is committed.
    @State private var smallText = ""
    @State private var mediumText = ""
    @State private var sizeNote: String?

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Export defaults") {
                Picker("Size", selection: $settings.values.sizePreset) {
                    ForEach(SizePreset.allCases, id: \.self) { Text($0.settingsName).tag($0) }
                }
                .accessibilityIdentifier("settingsPreset")

                Picker("GIF frame rate", selection: $settings.values.gifFrameRate) {
                    ForEach(GifFrameRate.allCases, id: \.self) { Text($0.settingsName).tag($0) }
                }
                .accessibilityIdentifier("settingsRate")

                Picker("Mode", selection: $settings.values.mode) {
                    ForEach(PlaybackMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .accessibilityIdentifier("settingsMode")

                Picker("Format", selection: $settings.values.format) {
                    ForEach(ExportFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .accessibilityIdentifier("settingsFormat")

                if let reason = ExportMatrix.reason(format: settings.values.format, mode: settings.values.mode) {
                    Text("\(reason) Loop photos will open as GIF.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settingsFormatReason")
                }
            }

            Section {
                sizeField("Small (long edge, px)", text: $smallText, id: "settingsSmall") { commitSmall() }
                sizeField("Medium (long edge, px)", text: $mediumText, id: "settingsMedium") { commitMedium() }
                if let sizeNote {
                    Text(sizeNote).font(.footnote).foregroundStyle(.orange)
                        .accessibilityIdentifier("settingsSizeNote")
                }
            } header: {
                Text("Preset sizes")
            } footer: {
                Text("Between \(PresetSizes.allowedRange.lowerBound) and \(PresetSizes.allowedRange.upperBound) px, and Small stays smaller than Medium. Full is always the photo's own size.")
            }

            Section {
                Button("Reset to defaults", role: .destructive) {
                    settings.values = ExportDefaults()
                    sizeNote = nil
                    loadSizeText()
                }
                .accessibilityIdentifier("settingsReset")
            } footer: {
                Text("Restores the sizes, frame rate, mode and format the app shipped with.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadSizeText)
        // A number typed but not submitted still counts when the screen is left.
        .onDisappear { commitSmall(); commitMedium() }
    }

    private func sizeField(_ title: String, text: Binding<String>, id: String, commit: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("px", text: text)
                .keyboardType(.numbersAndPunctuation) // a number pad has no Return key to submit with
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
                .onSubmit(commit)
                .accessibilityIdentifier(id)
        }
    }

    private func loadSizeText() {
        smallText = String(settings.values.presetSizes.small)
        mediumText = String(settings.values.presetSizes.medium)
    }

    private func commitSmall() { commit(smallText) { $0.setSmall($1) } }
    private func commitMedium() { commit(mediumText) { $0.setMedium($1) } }

    /// Applies a typed number. Out-of-range or out-of-order input is clamped and the reason shown,
    /// never ignored without a word.
    private func commit(_ text: String, _ apply: (inout PresetSizes, Int) -> PresetSizes.Edit) {
        var sizes = settings.values.presetSizes
        if let value = Int(text.trimmingCharacters(in: .whitespaces)) {
            switch apply(&sizes, value) {
            case .accepted: sizeNote = nil
            case .adjusted(_, let reason): sizeNote = reason
            }
            settings.values.presetSizes = sizes
        } else {
            sizeNote = "Enter a whole number of pixels."
        }
        loadSizeText()
    }
}

private extension SizePreset {
    var settingsName: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .full: return "Full"
        }
    }
}

private extension GifFrameRate {
    var settingsName: String { self == .fps16_67 ? "16.7 fps" : "\(Int(framesPerSecond)) fps" }
}
