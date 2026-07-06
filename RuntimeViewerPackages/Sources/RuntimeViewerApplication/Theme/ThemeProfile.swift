#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import Semantic
import UIFoundation
import RuntimeViewerCore

/// A resolved, render-ready theme. Concrete themes are data-driven and stored
/// in `Settings.Theme`; the conformance that maps `SemanticType` to colors and
/// fonts lives in `ThemePreset+ThemeProfile.swift`.
public protocol ThemeProfile {
    var selectionBackgroundColor: NSUIColor { get }
    var backgroundColor: NSUIColor { get }
    var fontSize: CGFloat { get }
    func font(for type: SemanticType) -> NSUIFont
    func color(for type: SemanticType) -> NSUIColor
}
