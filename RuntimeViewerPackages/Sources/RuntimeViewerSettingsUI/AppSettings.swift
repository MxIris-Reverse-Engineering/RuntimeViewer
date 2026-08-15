#if os(macOS)

import RuntimeViewerSettings
import UIFoundationSettings

/// Collapses the model parameter so pages read `@AppSettings(\.theme)` rather
/// than naming RuntimeViewer's schema at every call site.
///
/// macOS-only, like every page that uses it: UIFoundation's Settings products
/// are attached to this target for macOS alone, so an unguarded import would
/// fail to build this module for the package's other declared platforms.
typealias AppSettings<Value> = UIFoundationSettings.AppSettings<RuntimeViewerSettings.Settings, Value>

#endif
