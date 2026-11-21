import AppKit
import Dependencies

/// The app's document controller. A file that is not a RuntimeViewer document
/// — a Mach-O file, a bundle, a folder, a dyld shared cache — opens in
/// a window on an engine reading it (`FileController`), whether it comes
/// from File › Open…, Open Recent or the Dock.
///
/// The first `NSDocumentController` made becomes `NSDocumentController.shared`,
/// so `install()` runs in `AppDelegate.main()`, before `NSApplication.run()`:
/// window restoration inside `run()` reaches for the shared controller, and
/// would make a plain one.
@MainActor
final class DocumentController: NSDocumentController {
    @Dependency(\.fileController) private var fileController

    /// Makes this the shared document controller.
    static func install() {
        _ = DocumentController()
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?, completionHandler: @escaping (Int) -> Void) {
        openPanel.message = "Choose a Mach-O file, an app or framework bundle, a folder, or a dyld shared cache to read from disk."
        // A framework and a folder are directories to the panel, and an app
        // is read whole, never browsed into.
        openPanel.canChooseDirectories = true
        openPanel.treatsFilePackagesAsDirectories = false
        // Any file: a dyld shared cache has no type of its own, and an
        // executable is often typed by nothing more than its permissions.
        super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
    }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        guard fileController.opensFile(at: url) else {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
            return
        }
        Task {
            do {
                // Returns as soon as the window is up; the file is read in the
                // background, and joins Open Recent once it has been.
                let document = try await fileController.openDocument(forFileAt: url, display: displayDocument)
                completionHandler(document, false, nil)
            } catch {
                // The controller presents it: "… is not a Mach-O file, a
                // bundle or a dyld shared cache". Why the service could not
                // read a file the window it opened says itself.
                completionHandler(nil, false, error)
            }
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        // File › New. What AppKit's validation answers for an action it does
        // not define is not documented; a new window on My Mac can always be
        // opened.
        if item.action == #selector(newDocumentWithoutPointerAnimation(_:)) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }
}

extension NSDocumentController {
    /// File › New and the Welcome window's New Window on My Mac:
    /// `newDocument(_:)`, except that the new window appears where it is
    /// placed instead of flying out of the pointer — as Xcode's new windows do.
    ///
    /// `openUntitledDocumentAndDisplay(true)` shows the new document's windows
    /// inside a bracket in which AppKit, when the event being handled is a
    /// mouse-up, records where the pointer is. The window's opening animation
    /// then starts with its top-left corner at the pointer and swings it into
    /// place, so a click in the middle of the screen sends a large window in
    /// from the bottom right (`_NSWindowTransformAnimation`, macOS 27.2).
    /// Xcode never takes that path — it makes the document without displaying
    /// it and shows the windows itself — and neither does this. The window
    /// still scales up where it is, as any new document window does.
    ///
    /// The tab bar's + button is left on AppKit's path: what makes its new
    /// window a tab is cleared inside `openUntitledDocumentAndDisplay(_:)`,
    /// before windows shown here would see it.
    @objc func newDocumentWithoutPointerAnimation(_ sender: Any?) {
        do {
            let document = try openUntitledDocumentAndDisplay(false)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            presentError(error)
        }
    }
}
