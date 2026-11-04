#if os(macOS)

import AppKit

/// The view of the toolbar item in the middle of the toolbar in Xcode 27's style: Xcode 27.2's
/// `IDESchemePickerToolbarView`, holding the runtime source picker 4 points in from either side at
/// full height.
///
/// NSToolbar measures an item's view in a layout engine of its own, pulling it to zero and to
/// 10,000 points wide at priority 200 (see `TitleToolbarItem`), so the three constraints Xcode puts on
/// the view, all at priority 999, decide the item's size: 28 points tall, at least 87 wide, and at
/// most as wide as the picker wants plus the two insets — and never less than 87. The maximum follows
/// the picker's title and icon; the glass capsule around the item is AppKit's. Spec:
/// `/Volumes/RE/Xcode/27.2-27B52/README.md`, "Scheme picker in the middle of the toolbar".
public final class RuntimeSourcePickerToolbarView: NSView {
    static let height: CGFloat = 28

    static let minimumWidth: CGFloat = 87

    /// Between the view's edges and the picker, on either side.
    static let horizontalInset: CGFloat = 4

    static let sizePriority = NSLayoutConstraint.Priority(999)

    public let picker = RuntimeSourcePicker(style: .toolbar)

    private lazy var maximumWidthConstraint = widthAnchor.constraint(lessThanOrEqualToConstant: Self.minimumWidth)

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: Self.height))
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        let heightConstraint = heightAnchor.constraint(equalToConstant: Self.height)
        let minimumWidthConstraint = widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth)
        for constraint in [heightConstraint, minimumWidthConstraint, maximumWidthConstraint] {
            constraint.priority = Self.sizePriority
            constraint.isActive = true
        }
        updateMaximumWidth()
        picker.changeHandler = { [weak self] change in
            guard let self, change == .wantedWidth else { return }
            updateMaximumWidth()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The widest the item gets: the picker's wanted width plus both insets, or the minimum width
    /// when that is more — `IDESchemePickerToolbarView.updateSizeConstraints()`.
    var maximumWidth: CGFloat {
        max(picker.wantedWidth + 2 * Self.horizontalInset, Self.minimumWidth)
    }

    private func updateMaximumWidth() {
        let maximumWidth = maximumWidth
        guard maximumWidthConstraint.constant != maximumWidth else { return }
        maximumWidthConstraint.constant = maximumWidth
    }

    public override func layout() {
        super.layout()
        picker.frame = NSRect(
            x: Self.horizontalInset,
            y: 0,
            width: max(bounds.width - 2 * Self.horizontalInset, 0),
            height: Self.height
        )
    }
}

#endif
