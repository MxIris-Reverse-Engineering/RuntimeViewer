import Foundation
import RuntimeViewerCore

/// One search of Open Quickly over a document's engine: the empty editor pane's start page and
/// the floating bar File › Open Quickly… opens search the same way, as Xcode's initial editor and
/// its Open Quickly window share one search (proposal `editor-start-page`).
///
/// The catalog — the engine's images and the objects of its indexed images — is read on the
/// first match and kept until `end()`, so the keystrokes of one search read it once and nothing of
/// it stays in memory between searches. It is read from the engine the document is on at that
/// moment; whoever ends searches on an engine switch ends this one too.
@MainActor
final class OpenQuicklySearch {
    private let documentState: DocumentState

    private var catalogTask: Task<OpenQuicklyCatalog, Never>?

    init(documentState: DocumentState) {
        self.documentState = documentState
    }

    /// The best `limit` entries matching `text`, best first; the catalog is read first when this
    /// search has none yet. Matching runs off the main thread: a catalog of every indexed image can
    /// hold hundreds of thousands of names. A caller already cancelled — its search was dropped,
    /// possibly by an `end()` that has just let the catalog go — gets nothing and reads nothing.
    func matches(for text: String, limit: Int) async -> [OpenQuicklyCatalog.Entry] {
        guard !Task.isCancelled else { return [] }
        let catalogTask = catalog()
        let catalog = await catalogTask.value
        return await Self.matches(in: catalog, for: text, limit: limit)
    }

    /// Ends the search: the catalog goes, and a read still under way stops.
    func end() {
        catalogTask?.cancel()
        catalogTask = nil
    }

    /// The catalog of this search, read on first use: the leaves of the engine's image tree, which
    /// only the main actor reads, and the objects of its indexed images. A catalog read while the
    /// engine lists no image yet — a file still being read, an engine still connecting — is not
    /// kept, so the next match reads again rather than searching nothing for the rest of the search.
    private func catalog() -> Task<OpenQuicklyCatalog, Never> {
        if let catalogTask { return catalogTask }
        let engine = documentState.runtimeEngine
        let imagePaths = engine.imageNodes.flatMap(\.leafImagePaths)
        let catalogTask = Task.detached {
            await OpenQuicklyCatalog.load(imagePaths: imagePaths, from: engine)
        }
        if !imagePaths.isEmpty {
            self.catalogTask = catalogTask
        }
        return catalogTask
    }

    private nonisolated static func matches(in catalog: OpenQuicklyCatalog, for text: String, limit: Int) async -> [OpenQuicklyCatalog.Entry] {
        guard !Task.isCancelled else { return [] }
        return catalog.matches(for: text, limit: limit)
    }

    /// A search that goes away mid-read stops reading the engine's objects for it.
    deinit {
        catalogTask?.cancel()
    }
}
