#if os(macOS)

import AppKit

/// Colours Xcode defines for itself on `DVTTheme` (DVTUserInterfaceKit),
/// rebuilt from Xcode 27.0 so RuntimeViewer's Xcode-style lists can match it.
/// None of them is an AppKit colour; each one's comment names the `DVTTheme`
/// getter it reproduces.
extension NSColor {
    // MARK: - Filter Results

    /// The part of a filter or find result that matches the query.
    ///
    /// `-[DVTTheme filterResultMatchingTextColor]` returns `textColor`.
    public static let filterResultMatchingTextColor: NSColor = .textColor

    /// The rest of a filter or find result.
    ///
    /// `-[DVTTheme filterResultNonMatchingTextColor]` resolves against the
    /// drawing appearance: `secondaryLabelColor` where the appearance allows
    /// vibrancy, otherwise white in a dark appearance and black in a light one,
    /// both at 75 % opacity.
    public static let filterResultNonMatchingTextColor = NSColor(name: "filterResultNonMatchingTextColor") { appearance in
        if appearance.allowsVibrancy {
            return .secondaryLabelColor
        }
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua:
            return NSColor.white.withAlphaComponent(0.75)
        default:
            return NSColor.black.withAlphaComponent(0.75)
        }
    }

    /// `filterResultMatchingTextColor` on a selected row.
    ///
    /// `-[DVTTheme selectedFilterResultMatchingTextColor]` returns
    /// `alternateSelectedControlTextColor`.
    public static let selectedFilterResultMatchingTextColor: NSColor = .alternateSelectedControlTextColor

    /// `filterResultNonMatchingTextColor` on a selected row.
    ///
    /// `-[DVTTheme selectedFilterResultNonMatchingTextColor]` is
    /// `selectedFilterResultMatchingTextColor` at 75 % opacity. Xcode derives it
    /// on every call; the provider does the same, so the system colour
    /// underneath keeps following the appearance.
    public static let selectedFilterResultNonMatchingTextColor = NSColor(name: "selectedFilterResultNonMatchingTextColor") { _ in
        NSColor.selectedFilterResultMatchingTextColor.withAlphaComponent(0.75)
    }

    // MARK: - Parameters

    /// `-[DVTTheme parameterTextColor]` is the colour named `parameterTextColor`
    /// in DVTUserInterfaceKit's asset catalog: grey 0.431 in a light appearance
    /// and 0.569 in a dark one. The catalog stores them in extended grey, which
    /// has the colorimetry of generic gamma 2.2 grey, and has no high-contrast
    /// variants.
    public static let parameterTextColor = NSColor(name: "parameterTextColor") { appearance in
        switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
        case .darkAqua:
            return NSColor(genericGamma22White: 0.569, alpha: 1)
        default:
            return NSColor(genericGamma22White: 0.431, alpha: 1)
        }
    }
}

#endif
