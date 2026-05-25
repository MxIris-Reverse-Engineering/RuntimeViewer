import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures

/// `NSButton`-backed implementation of `UXBackButtonProtocol` that we register
/// with `UXKitBehavior.sharedBehavior.backButtonClass` at launch. The default
/// OpenUXKit back button is a `NSSegmentedControl` subclass, and on macOS 26
/// `NSSegmentedControl` is internally reimplemented on top of SwiftUI /
/// DesignLibrary — every navbar push therefore triggers a `ViewGraph.sizeThatFits`
/// pass during the transition completion handler, which Time Profiler shows
/// costs 20-35 ms per push. Replacing the back button with an `NSButton`
/// (whose `NSButtonCell` rendering path stays pure AppKit on macOS 26) removes
/// that synchronous SwiftUI work entirely.
///
/// We don't actually see the back button anywhere in this app — every
/// `UXKitNavigationController` keeps its `isNavigationBarHidden` flag on — so
/// we don't bother modelling the chevron/title appearance. We just need the
/// view to exist, accept the protocol-required setters, and lay out as a
/// zero-cost AppKit control.
final class LightBackButton: NSButton, UXBackButtonProtocol {
    private var _hidesTitle: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        bezelStyle = .accessoryBarAction
        isBordered = false
        imagePosition = .imageLeading
        translatesAutoresizingMaskIntoConstraints = false
        font = .systemFont(ofSize: NSFont.systemFontSize)
    }
    
    var hidesTitle: Bool {
        get { _hidesTitle }
        set {
            guard _hidesTitle != newValue else { return }
            _hidesTitle = newValue
            if newValue {
                imagePosition = .imageOnly
                toolTip = title
            } else {
                imagePosition = .imageLeading
                toolTip = nil
            }
        }
    }
}
