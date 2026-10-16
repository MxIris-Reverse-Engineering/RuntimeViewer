import AppKit
import RuntimeViewerApplication

final class Document: NSDocument {
    private static var nextDocumentNumber = 1
    
    let mcpIdentifier: String = {
        let id = "document\(Document.nextDocumentNumber)"
        Document.nextDocumentNumber += 1
        return id
    }()
    
    let documentState = DocumentState()

    private lazy var mainCoordinator = MainCoordinator(documentState: documentState)

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(mainCoordinator.windowController)
        // The engine's background indexing, shared with every document on the
        // engine: the first document opened on it starts it.
        documentState.backgroundIndexingCoordinator.documentDidOpen()
        // Joined here, like the indexing coordinator: the engine's corpus
        // coordinator, shared the same way, keeps its interface corpus in step
        // with what the engine indexes, and this document's Find session
        // follows it.
        _ = documentState.findCorpusCoordinator
        // Keeps the app out of App Nap while either coordinator has work in
        // progress, so the local-runtime service doing it keeps its priority
        // when the user switches to another app.
        _ = documentState.backgroundWorkProcessActivity
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
