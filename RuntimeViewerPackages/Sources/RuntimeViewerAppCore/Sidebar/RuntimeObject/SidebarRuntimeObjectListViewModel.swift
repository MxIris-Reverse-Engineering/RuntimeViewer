import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

// Not `final`: tests subclass this to seed a canned object list through
// the real `reloadData` path (mirroring `SidebarRuntimeObjectViewModel`,
// which is subclassable for the same reason).
public class SidebarRuntimeObjectListViewModel: SidebarRuntimeObjectViewModel {
    public typealias CellLookup = (cell: SidebarRuntimeObjectCellViewModel, ancestors: [SidebarRuntimeObjectCellViewModel])

    /// Latest non-nil root object the document is inspecting, waiting to
    /// be resolved to a concrete cell once it appears in `nodes`. Driven
    /// by `documentState.$selectedRuntimeObject`, the focused editor pane's
    /// object (see `transform`) — never by an external imperative call.
    private let pendingSelectRelay = PublishRelay<RuntimeObject>()

    /// Requests from `revealSelectedRuntimeObject()`, each carrying the
    /// object that was on screen when the command ran.
    private let revealRequestRelay = PublishRelay<RuntimeObject>()

    override var isSorted: Bool { true }

    public static func findCell(
        for object: RuntimeObject,
        in nodes: [SidebarRuntimeObjectCellViewModel]
    ) -> CellLookup? {
        findCell(for: object, in: nodes, children: \.children)
    }

    /// `findCell(for:in:)` over every row, the ones the filter currently
    /// hides included: a cell's `children` is the filtered view of its subtree.
    static func findCellIgnoringFilter(
        for object: RuntimeObject,
        in nodes: [SidebarRuntimeObjectCellViewModel]
    ) -> CellLookup? {
        findCell(for: object, in: nodes, children: \.unfilteredChildren)
    }

    private static func findCell(
        for object: RuntimeObject,
        in nodes: [SidebarRuntimeObjectCellViewModel],
        children: KeyPath<SidebarRuntimeObjectCellViewModel, [SidebarRuntimeObjectCellViewModel]>
    ) -> CellLookup? {
        for node in nodes {
            if node.runtimeObject == object { return (node, []) }
            if let inner = findCell(for: object, in: node[keyPath: children], children: children) {
                return (inner.cell, [node] + inner.ancestors)
            }
        }
        return nil
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let addBookmark: Signal<SidebarRuntimeObjectCellViewModel>
    }

    public struct Output {
        public let selectCell: Signal<CellLookup>
        /// The row to bring into view for `revealSelectedRuntimeObject()`,
        /// with its ancestors outermost first. A search text or scope that hid
        /// the row has already been cleared when this fires.
        public let revealCell: Signal<CellLookup>
        /// A reveal request for an object this image's list does not contain.
        public let revealFailed: Signal<Void>
    }

    /// What a reveal request comes to; split into `Output.revealCell` and
    /// `Output.revealFailed`.
    private enum RevealOutcome {
        case revealed(CellLookup)
        case notFound

        var revealedCell: CellLookup? {
            guard case .revealed(let cellLookup) = self else { return nil }
            return cellLookup
        }

        var isNotFound: Bool {
            guard case .notFound = self else { return false }
            return true
        }
    }

    /// Brings the object on screen into view in this list — Navigate ▸
    /// Reveal in Sidebar Navigator. Answered through `Output.revealCell`, or
    /// through `Output.revealFailed` when the list does not contain the object.
    ///
    /// The follow set up in `transform(_:)` fires only when
    /// `selectedRuntimeObject` changes. This answers every call, because the
    /// object is usually the one already selected — since scrolled away,
    /// collapsed or filtered out. A request made while the list is still
    /// loading waits for the load, and a newer request replaces one still
    /// waiting.
    public func revealSelectedRuntimeObject() {
        guard let selectedRuntimeObject = documentState.selectedRuntimeObject else { return }
        revealRequestRelay.accept(selectedRuntimeObject)
    }

    /// Waits for the list to be loaded, then resolves the request once.
    ///
    /// Keyed on `filteredNodes` emissions, and only on those seen once
    /// `loadState` is `.loaded`: a reload publishes `.loaded` *before* it
    /// installs the new cells, in the same main-actor block, so waking on the
    /// load state would resolve against the previous load's cells. The relay
    /// replays its current value, which answers a request against an already
    /// loaded list straight away.
    ///
    /// The resolution itself runs a main-queue turn later, outside the
    /// emission that woke it: clearing the filter reassigns `filteredNodes`,
    /// which would re-enter the relay while it is still delivering.
    private func revealOutcome(for runtimeObject: RuntimeObject) -> Observable<RevealOutcome> {
        switch loadState {
        case .notLoaded, .loadError:
            // Nothing is listed until the user loads the image.
            return .just(.notFound)
        case .unknown, .loading, .loaded:
            return $filteredNodes
                .asObservable()
                .filter { [weak self] _ in self?.loadState == .loaded }
                .take(1)
                .observe(on: MainScheduler.asyncInstance)
                .compactMap { [weak self] _ in self?.resolveReveal(of: runtimeObject) }
        }
    }

    /// Finds the row for `runtimeObject` in the list as displayed, clearing
    /// the search text and the scope first when they are what hides it.
    private func resolveReveal(of runtimeObject: RuntimeObject) -> RevealOutcome {
        if let displayedCell = Self.findCell(for: runtimeObject, in: filteredNodes) {
            return .revealed(displayedCell)
        }
        // Only clear a filter that is actually in the way: for an object the
        // list does not contain at all, the user would lose it for nothing.
        guard Self.findCellIgnoringFilter(for: runtimeObject, in: nodes) != nil else {
            return .notFound
        }
        clearFilter()
        guard let revealedCell = Self.findCell(for: runtimeObject, in: filteredNodes) else {
            return .notFound
        }
        return .revealed(revealedCell)
    }

    /// The image's Objective-C and Swift objects, then its C++ classes and namespaces: the list is
    /// one of the three places that ask for C++ objects, with the jump bar and the image page
    /// (proposal `cplusplus-objects`).
    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        try await runtimeEngine.objects(in: imagePath, includesCPlusPlusObjects: true)
    }

    /// The image's objects with the progress of building them. Building an image the engine has not
    /// indexed is the user opening it, which the Report's Manual Loading records (proposal
    /// `editor-jump-bar`); a reload of an indexed one — after every batch of background indexing —
    /// is not.
    override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                let runtimeEngine = runtimeEngine
                let imagePath = imagePath
                let streamObjects: @Sendable (_ reportProgress: @escaping @Sendable (RuntimeObjectsLoadingProgress) async -> Void) async throws -> Void = { reportProgress in
                    for try await event in await runtimeEngine.objectsWithProgress(in: imagePath, includesCPlusPlusObjects: true) {
                        if case .progress(let progress) = event {
                            await reportProgress(progress)
                        }
                        continuation.yield(event)
                    }
                }
                do {
                    if try await runtimeEngine.isImageIndexed(path: imagePath) {
                        try await streamObjects { _ in }
                    } else {
                        try await documentState.recordingManualLoad(ofImageAt: imagePath, streamObjects)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func transform(_ input: Input) -> Output {
        input.addBookmark.emitOnNext { [weak self] viewModel in
            guard let self else { return }
            let bookmarkKey = documentState.runtimeEngine.bookmarkScope.bookmarkKey
            appDefaults.objectBookmarksByScopeAndImagePath[bookmarkKey, default: [:]][imagePath, default: []].append(.init(object: viewModel.runtimeObject))
        }
        .disposed(by: rx.disposeBag)

        // Visual selection follows whatever the document is currently
        // showing. `selectedRuntimeObject` is the display layer's single
        // source of truth — sidebar clicks, toolbar previous/next, history
        // menu jumps, specialization completion, and tab switches all land
        // as a new value here, so one subscription covers them all.
        documentState.$selectedRuntimeObject
            .asObservable()
            .compactMap { $0 }
            .distinctUntilChanged()
            .bind(to: pendingSelectRelay)
            .disposed(by: rx.disposeBag)

        let pendingResolved: Signal<CellLookup> = pendingSelectRelay
            .asObservable()
            .flatMapLatest { [weak self] object -> Observable<CellLookup> in
                guard let self else { return .empty() }
                return self.$nodes
                    .asObservable()
                    .compactMap { Self.findCell(for: object, in: $0) }
                    .take(1)
            }
            .asSignal(onErrorSignalWith: .empty())

        let revealOutcomes: Signal<RevealOutcome> = revealRequestRelay
            .asObservable()
            .flatMapLatest { [weak self] runtimeObject -> Observable<RevealOutcome> in
                guard let self else { return .empty() }
                return revealOutcome(for: runtimeObject)
            }
            .asSignal(onErrorSignalWith: .empty())

        return Output(
            selectCell: pendingResolved,
            revealCell: revealOutcomes.compactMap(\.revealedCell),
            revealFailed: revealOutcomes.filter(\.isNotFound).mapToVoid()
        )
    }
}
