import AppKit
import Dependencies

/// The app's document controller. A file that is not a RuntimeViewer document
/// — a Mach-O file, a bundle, a folder, a dyld shared cache — opens offline, in
/// a window on an engine reading it (`OfflineFileController`), whether it comes
/// from File › Open…, Open Recent or the Dock.
///
/// The first `NSDocumentController` made becomes `NSDocumentController.shared`,
/// so `install()` runs in `AppDelegate.main()`, before `NSApplication.run()`:
/// window restoration inside `run()` reaches for the shared controller, and
/// would make a plain one.
@MainActor
final class DocumentController: NSDocumentController {
    @Dependency(\.offlineFileController) private var offlineFileController

    /// Makes this the shared document controller.
    static func install() {
        _ = DocumentController()
    }

    override func beginOpenPanel(_ openPanel: NSOpenPanel, forTypes inTypes: [String]?, completionHandler: @escaping (Int) -> Void) {
        openPanel.message = "Choose a Mach-O file, an app or framework bundle, a folder, or a dyld shared cache to read offline."
        // A framework and a folder are directories to the panel, and an app
        // is read whole, never browsed into.
        openPanel.canChooseDirectories = true
        openPanel.treatsFilePackagesAsDirectories = false
        // Any file: a dyld shared cache has no type of its own, and an
        // executable is often typed by nothing more than its permissions.
        super.beginOpenPanel(openPanel, forTypes: nil, completionHandler: completionHandler)
    }

    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void) {
        guard offlineFileController.opensFile(at: url) else {
            super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
            return
        }
        Task {
            do {
                // Returns as soon as the window is up; the file is read in the
                // background, and joins Open Recent once it has been.
                let document = try await offlineFileController.openDocument(forFileAt: url, display: displayDocument)
                completionHandler(document, false, nil)
            } catch {
                // The controller presents it: "… is not a Mach-O file, a
                // bundle or a dyld shared cache". Why the service could not
                // read a file the window it opened says itself.
                completionHandler(nil, false, error)
            }
        }
    }
}
