// The only file that imports UIKit. SwiftUI has no "open this app's page in Settings" action, and
// the documented constant for that URL lives in UIKit.
import SwiftUI
import UIKit

enum OpenSettings {
    static var url: URL? {
        URL(string: UIApplication.openSettingsURLString)
    }
}
