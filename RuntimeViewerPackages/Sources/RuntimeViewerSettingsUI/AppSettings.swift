import RuntimeViewerSettings
import UIFoundationSettingsUI

/// Collapses the model parameter so pages read `@AppSettings(\.theme)` rather
/// than naming RuntimeViewer's schema at every call site.
///
/// On every platform: UIFoundation's page building blocks build on macOS,
/// iOS, Mac Catalyst and visionOS, and the iOS settings screen uses the same
/// pages as the macOS window.
typealias AppSettings<Value> = UIFoundationSettingsUI.AppSettings<RuntimeViewerSettings.Settings, Value>
