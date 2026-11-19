import AppKit
import RuntimeViewerUI

/// The naming word cloud's window: a regular window of its own, beside the
/// document's, with a unified toolbar whose items its content supplies, that
/// remembers its size and position per image.
final class NamingWordCloudWindowController: XiblessWindowController<NSWindow> {
    private static let defaultContentSize = NSSize(width: 1100, height: 720)

    /// Wide enough for the toolbar's items, the member groups included, to
    /// stay out of its overflow menu.
    private static let minimumContentSize = NSSize(width: 900, height: 460)

    private static let toolbarIdentifier = NSToolbar.Identifier("NamingWordCloud")

    /// - Parameters:
    ///   - title: The window's title.
    ///   - subtitle: The image the window is about, under the title.
    ///   - autosaveName: The name its frame is remembered under.
    ///   - toolbarDelegate: What supplies the toolbar's items: the window's content.
    func configure(title: String, subtitle: String, autosaveName: String, toolbarDelegate: NSToolbarDelegate) {
        guard let window else { return }
        window.title = title
        window.subtitle = subtitle
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.toolbarStyle = .unified
        window.contentMinSize = Self.minimumContentSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        // A frame saved under this name before wins; otherwise the default size, centred.
        if !window.setFrameUsingName(autosaveName) {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)
    }
}
