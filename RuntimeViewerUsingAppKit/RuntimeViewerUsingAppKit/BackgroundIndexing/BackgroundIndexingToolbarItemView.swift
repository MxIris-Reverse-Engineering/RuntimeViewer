import AppKit
import RuntimeViewerUI
import SnapKit

enum BackgroundIndexingToolbarState: Equatable {
    case idle
    case disabled
    case indexing
    case hasFailures
}

final class BackgroundIndexingToolbarItemView: NSView {
    /// Click-receiving control. `NSToolbarItem` with a non-control custom view
    /// does NOT route clicks to the item's target/action — only NSControl
    /// subclasses inside the view do. Wrapping the icon in a `ToolbarButton`
    /// gives both the standard toolbar bezel + click handling. The spinner
    /// and failure dot are click-through overlays on top.
    let button = ToolbarButton().then {
        $0.image = NSImage(
            systemSymbolName: "square.stack.3d.down.right",
            accessibilityDescription: nil)
        $0.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        $0.imagePosition = .imageOnly
        $0.title = ""
    }
    private let spinner = ClickThroughProgressIndicator().then {
        $0.style = .spinning
        $0.controlSize = .small
        $0.isIndeterminate = true
        $0.isDisplayedWhenStopped = false
    }
    private let failureDot = ClickThroughView()

    var state: BackgroundIndexingToolbarState = .idle {
        didSet { applyState() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayout()
        applyState()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupLayout() {
        // Button fills the view, then overlays paint on top.
        addSubview(button)
        addSubview(spinner)
        addSubview(failureDot)

        button.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        spinner.snp.makeConstraints { make in
            make.center.equalToSuperview()
            make.width.height.equalTo(14)
        }
        failureDot.snp.makeConstraints { make in
            make.width.height.equalTo(6)
            make.trailing.bottom.equalTo(button).inset(2)
        }
        failureDot.wantsLayer = true
        failureDot.layer?.cornerRadius = 3
        failureDot.layer?.backgroundColor = NSColor.systemRed.cgColor
    }

    private func applyState() {
        switch state {
        case .idle:
            // Default toolbar tint — looks "live" like other toolbar buttons.
            // Using `.secondaryLabelColor` here previously made the icon look
            // disabled compared to its peers.
            button.contentTintColor = nil
            spinner.stopAnimation(nil)
            failureDot.isHidden = true
        case .disabled:
            button.contentTintColor = .tertiaryLabelColor
            spinner.stopAnimation(nil)
            failureDot.isHidden = true
        case .indexing:
            button.contentTintColor = .controlAccentColor
            spinner.startAnimation(nil)
            failureDot.isHidden = true
        case .hasFailures:
            button.contentTintColor = .controlAccentColor
            spinner.startAnimation(nil)
            failureDot.isHidden = false
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
}

/// AppKit lacks UIView's `isUserInteractionEnabled`. Overlays that must let
/// clicks fall through to the button beneath need a `hitTest(_:)` returning
/// `nil` for every point.
private final class ClickThroughProgressIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class ClickThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
