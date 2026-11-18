import AppKit
import RuntimeViewerUI

/// The naming word cloud's window: a regular window of its own, beside the
/// document's, that remembers its size and position per image.
final class NamingWordCloudWindowController: XiblessWindowController<NSWindow> {
    private static let defaultContentSize = NSSize(width: 1100, height: 720)

    private static let minimumContentSize = NSSize(width: 720, height: 460)

    func configure(title: String, autosaveName: String) {
        guard let window else { return }
        window.title = title
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.contentMinSize = Self.minimumContentSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // A frame saved under this name before wins; otherwise the default size, centred.
        if !window.setFrameUsingName(autosaveName) {
            window.setContentSize(Self.defaultContentSize)
            window.center()
        }
        window.setFrameAutosaveName(autosaveName)
    }
}
