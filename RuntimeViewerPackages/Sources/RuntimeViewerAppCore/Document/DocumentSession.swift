import Foundation
import RuntimeViewerCore

/// One window's document: its ``DocumentState``, and the two steps every front
/// end takes with it — joining the engine's background work before the
/// window's UI binds, and leaving it, with whatever the document brought into
/// being, when the window goes.
///
/// The macOS app's `Document` holds one, and so does each window of the iOS
/// apps (``DocumentSessionRegistry``). Neither front end calls
/// ``DocumentState/startBackgroundWork()`` or
/// ``DocumentState/documentWillClose()`` itself.
@MainActor
public final class DocumentSession {
    private static var nextNumber = 1

    /// The order this session was made in within this process, from 1. The
    /// macOS app names its documents to MCP clients by it.
    public let number: Int

    public let documentState: DocumentState

    /// A session on `runtimeEngine`, not opened yet.
    public init(runtimeEngine: RuntimeEngine) {
        number = Self.nextNumber
        Self.nextNumber += 1
        documentState = DocumentState(runtimeEngine: runtimeEngine)
    }

    /// Joins the engine's background work — its indexing, its interface
    /// corpus and its prepared cross references, shared with every document
    /// on the engine — which the pages show and the document's Find session
    /// follows. Call before the document's UI binds. Only the first call does
    /// anything, and none after ``close()``.
    public func open() {
        documentState.startBackgroundWork()
    }

    /// Leaves the engine's background work and closes what this document
    /// brought into being, opened or not. Only the first call does anything.
    public func close() {
        documentState.documentWillClose()
    }
}
