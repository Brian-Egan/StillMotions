import Observation
import StillMotionsPipeline

/// The user's default export choices, observable by SwiftUI and saved as they change.
///
/// All the defaults, the saving and the tolerance of old stored values live in the package's
/// `ExportDefaultsStore`, where `swift test` covers them; this class only makes that observable.
/// The settings SCREEN is a later issue (#34); this is the store behind it.
@MainActor
@Observable
final class AppSettings {
    private let store: ExportDefaultsStore

    var values: ExportDefaults {
        didSet { store.save(values) }
    }

    init(store: ExportDefaultsStore = ExportDefaultsStore()) {
        self.store = store
        values = store.load()
    }
}
