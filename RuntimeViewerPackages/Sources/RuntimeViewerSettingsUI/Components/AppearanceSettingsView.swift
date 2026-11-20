#if os(iOS) || os(visionOS)

import SwiftUI
import UIFoundationSettingsUI

/// The iOS Appearance page: the appearance section alone. The rest of the
/// macOS General page — toolbar style, quitting after the last window, the
/// sidebar's expansion depth — has nothing to act on there.
struct AppearanceSettingsView: View {
    var body: some View {
        SettingsForm {
            AppearanceSettingsSection()
        }
    }
}

#endif
