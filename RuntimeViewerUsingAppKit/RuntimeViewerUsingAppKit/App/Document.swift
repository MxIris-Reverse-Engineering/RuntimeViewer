import AppKit
import RuntimeViewerApplication
import RuntimeViewerCore

final class Document: NSDocument {
    private static var nextDocumentNumber = 1
    
    let mcpIdentifier: String = {
        let id = "document\(Document.nextDocumentNumber)"
        Document.nextDocumentNumber += 1
        return id
    }()
    
    let documentState: DocumentState

    private lazy var mainCoordinator = MainCoordinator(documentState: documentState)

    /// A document whose window starts on `runtimeEngine`: an offline file's
    /// engine for a file the user opened, `.local` for a new window.
    init(runtimeEngine: RuntimeEngine) {
        documentState = DocumentState(runtimeEngine: runtimeEngine)
        super.init()
    }

    /// File › New and every other untitled document start on "My Mac".
    ///
    /// Overridden as a convenience initializer on purpose: `init()` is
    /// NSDocument's only designated initializer, and implementing it keeps
    /// the class inheriting NSDocument's convenience ones —
    /// `init(type:)`, `init(contentsOf:ofType:)`,
    /// `init(for:withContentsOf:ofType:)` — which AppKit calls from
    /// Objective-C when it opens or restores a document. A subclass that does
    /// not inherit them traps there instead.
    override convenience init() {
        self.init(runtimeEngine: .local)
    }

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        // First, before any page binds: the engine's background work — its
        // indexing, its interface corpus and its prepared cross references,
        // shared with every document on the engine — which the pages show and
        // this document's Find session follows, and the activity that keeps
        // the app out of App Nap while any of it is in progress.
        documentState.startBackgroundWork()
        addWindowController(mainCoordinator.windowController)
    }

    override func close() {
        // Closes only the members this document brought into being.
        documentState.documentWillClose()
        super.close()
    }

    override func data(ofType typeName: String) throws -> Data {
        throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        throw NSError(domain: NSOSStatusErrorDomain, code: unimpErr, userInfo: nil)
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {}
    override func runPageLayout(_ sender: Any?) {}
    override func printDocument(_ sender: Any?) {}
    override func saveAs(_ sender: Any?) {}
    override func saveTo(_ sender: Any?) {}
    override func save(_ sender: Any?) {}
    override func revertToSaved(_ sender: Any?) {}

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(revertToSaved(_:)),
             #selector(save(_:)),
             #selector(saveAs(_:)),
             #selector(saveTo(_:)),
             #selector(printDocument(_:)),
             #selector(runPageLayout(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}
