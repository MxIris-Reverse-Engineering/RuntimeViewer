#if os(macOS)

import AppKit
import SnapKit
import UIFoundation

/// The controls a scrollable canvas floats in a corner, as a map or an image
/// viewer does: a hand tool, zoom out, the zoom level, zoom in and zoom to
/// fit, on a `FloatingPlatterView`.
///
/// It only holds the buttons — whoever owns the scroll view acts on their
/// actions — and shows the magnification it is given as a whole percentage,
/// greying out a zoom button once the magnification reaches that end of its
/// range. The hand tool is a toggle that shows its filled symbol while on.
/// The zoom buttons answer Preview's shortcuts: ⌘= (⌘+) and ⌘− zoom, ⌘0
/// goes back to actual size and ⌘9 fits.
public final class CanvasControlsView: NSView {
    // MARK: - Controls

    public let handToolButton = CanvasControlsView.makeIconButton(symbolName: "hand.raised", toolTip: "Hand Tool")

    public let zoomOutButton = CanvasControlsView.makeIconButton(symbolName: "minus.magnifyingglass", toolTip: "Zoom Out (⌘−)")

    /// Shows the zoom level; a click goes back to actual size.
    public let zoomLevelButton = NSButton(title: "100%", target: nil, action: nil).then {
        $0.isBordered = false
        $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        $0.toolTip = "Actual Size (⌘0)"
        $0.setAccessibilityLabel("Actual Size")
    }

    public let zoomInButton = CanvasControlsView.makeIconButton(symbolName: "plus.magnifyingglass", toolTip: "Zoom In (⌘+)")

    public let zoomToFitButton = CanvasControlsView.makeIconButton(symbolName: "arrow.up.left.and.arrow.down.right", toolTip: "Zoom to Fit (⌘9)")

    // MARK: - State

    /// The canvas's magnification, shown as a percentage.
    public var magnification: CGFloat = 1 {
        didSet { updateZoomControls() }
    }

    /// The magnifications the canvas allows; a zoom button greys out at its end.
    public var magnificationRange: ClosedRange<CGFloat> = 0.1 ... 4 {
        didSet { updateZoomControls() }
    }

    /// "36%": a magnification as the zoom level shows it.
    public static func zoomLevelText(for magnification: CGFloat) -> String {
        "\(Int((magnification * 100).rounded()))%"
    }

    private static let buttonSide: CGFloat = 26

    /// How far from an end of the range a magnification still counts as at it.
    private static let magnificationTolerance: CGFloat = 0.001

    private let platterView = FloatingPlatterView(cornerRadius: 9)

    // MARK: - Lifecycle

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        handToolButton.setButtonType(.toggle)
        handToolButton.alternateImage = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "Hand Tool")

        // Preview's shortcuts. A window hands a key equivalent to its views
        // before the main menu sees it, so these win while the canvas's window
        // is key; a hidden button answers none.
        for (button, keyEquivalent) in [(zoomInButton, "="), (zoomOutButton, "-"), (zoomLevelButton, "0"), (zoomToFitButton, "9")] {
            button.keyEquivalent = keyEquivalent
            button.keyEquivalentModifierMask = .command
        }

        let stackView = HStackView(spacing: 2) {
            handToolButton
            Self.makeSeparator()
            zoomOutButton
            zoomLevelButton
            zoomInButton
            Self.makeSeparator()
            zoomToFitButton
        }
        stackView.edgeInsets = NSEdgeInsets(top: 2, left: 4, bottom: 2, right: 4)

        addSubview(platterView)
        platterView.contentView = stackView
        platterView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        zoomLevelButton.snp.makeConstraints { make in
            // Wide enough for "400%", so the buttons around it do not move as it changes.
            make.width.equalTo(40)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Canvas Controls")
        updateZoomControls()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateZoomControls() {
        zoomLevelButton.title = Self.zoomLevelText(for: magnification)
        zoomOutButton.isEnabled = magnification > magnificationRange.lowerBound + Self.magnificationTolerance
        zoomInButton.isEnabled = magnification < magnificationRange.upperBound - Self.magnificationTolerance
    }

    // MARK: - Building

    private static func makeIconButton(symbolName: String, toolTip: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip) ?? NSImage(), target: nil, action: nil)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.toolTip = toolTip
        button.snp.makeConstraints { make in
            make.size.equalTo(buttonSide)
        }
        return button
    }

    private static func makeSeparator() -> NSView {
        let separator = LayerBackedView()
        separator.backgroundColor = .separatorColor
        separator.snp.makeConstraints { make in
            make.width.equalTo(1)
            make.height.equalTo(16)
        }
        return separator
    }
}

#endif
