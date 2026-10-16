import Observation
import Photos

/// Whether the app may read the photo library, kept current for SwiftUI.
@MainActor
@Observable
final class PhotoLibraryAccess {
    enum State {
        case notDetermined
        case authorized
        /// The user chose "Selected Photos". The app works, on that subset.
        case limited
        case denied
        /// Blocked by something other than the user, such as parental controls, so the Settings
        /// app cannot grant it.
        case restricted

        var canReadLibrary: Bool { self == .authorized || self == .limited }
    }

    private(set) var state: State

    init() {
        state = Self.state(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Asks the system for access the first time, and does nothing once the user has answered.
    func requestIfNeeded() async {
        guard state == .notDetermined else { return }
        state = Self.state(for: await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    /// Re-reads the current status, for when the user comes back from the Settings app.
    func refresh() {
        state = Self.state(for: PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    private static func state(for status: PHAuthorizationStatus) -> State {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }
}
