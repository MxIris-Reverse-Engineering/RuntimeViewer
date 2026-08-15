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

    /// Fill behind the line the caret is on. Only the Xcode-backed content view draws it; the
    /// built-in `NSTextView` has no current-line highlight to colour.
    var currentLineHighlightColor: NSUIColor { get }
    var fontSize: CGFloat { get }
    func font(for type: SemanticType) -> NSUIFont
    func color(for type: SemanticType) -> NSUIColor
}
