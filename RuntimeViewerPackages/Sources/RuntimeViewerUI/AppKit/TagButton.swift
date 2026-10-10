#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import UIFoundation

/// A small capsule labelled with a word, at the trailing end of a list row: the system's badge
/// bezel (`BadgeButton`) at the small control size.
///
/// A tag that is not clickable only shows. It takes no part in hit-testing, so a click on it lands
/// on the row, the way a click on the row's title does. No tag takes the keyboard focus: a click
/// that moved focus out of the list would turn the list's selection the inactive grey.
public final class TagButton: BadgeButton {
    /// Whether a click on the tag sends its action. `false` leaves the click to the view behind it.
    public var isClickable = true {
        didSet {
            setAccessibilityRole(isClickable ? .button : .staticText)
        }
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refusesFirstResponder = true
        controlSize = .small
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        isClickable ? super.hitTest(point) : nil
    }
}

#endif
