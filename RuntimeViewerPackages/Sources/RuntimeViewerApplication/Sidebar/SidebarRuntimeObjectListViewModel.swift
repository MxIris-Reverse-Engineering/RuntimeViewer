import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public final class SidebarRuntimeObjectListViewModel: SidebarRuntimeObjectViewModel {
    public typealias CellLookup = (cell: SidebarRuntimeObjectCellViewModel, ancestors: [SidebarRuntimeObjectCellViewModel])

    @Observed public private(set) var searchStringForOpenQuickly: String = ""
    @Observed public private(set) var nodesForOpenQuickly: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var filteredNodesForOpenQuickly: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var isFilteringForOpenQuickly: Bool = false

    /// Latest non-nil root object the document is inspecting, waiting to
    /// be resolved to a concrete cell once it appears in `nodes`. Driven
    /// by `documentState.$selectionStack` (see `transform`) — never by an
    /// external imperative call.
    private let pendingSelectRelay = PublishRelay<RuntimeObject>()

    override var isSorted: Bool { true }

    public override init(imageNode: RuntimeImageNode, documentState: DocumentState, router: any Router<SidebarRuntimeObjectRoute>) {
        super.init(imageNode: imageNode, documentState: documentState, router: router)
    }

    public static func findCell(
        for object: RuntimeObject,
        in nodes: [SidebarRuntimeObjectCellViewModel]
    ) -> CellLookup? {
        for node in nodes {
            if node.runtimeObject == object { return (node, []) }
            if let inner = findCell(for: object, in: node.children) {
                return (inner.cell, [node] + inner.ancestors)
            }
        }
        return nil
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let runtimeObjectClickedForOpenQuickly: Signal<SidebarRuntimeObjectCellViewModel>
        public let searchStringForOpenQuickly: Signal<String>
        public let addBookmark: Signal<SidebarRuntimeObjectCellViewModel>
    }

    public struct Output {
        public let runtimeObjectsForOpenQuickly: Driver<[SidebarRuntimeObjectCellViewModel]>
        public let selectRuntimeObject: Signal<SidebarRuntimeObjectCellViewModel>
        public let selectCell: Signal<CellLookup>
    }

    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        try await runtimeEngine.objects(in: imagePath)
    }

    override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let stream = await runtimeEngine.objectsWithProgress(in: imagePath)
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    override func reloadData() async throws {
        try await super.reloadData()
        try Task.checkCancellation()

        await MainActor.run {
            self.searchStringForOpenQuickly = ""
            self.nodesForOpenQuickly = nodes.map { $0.runtimeObject }.sorted().map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: true) }
            self.filteredNodesForOpenQuickly = []
        }
    }

    public func transform(_ input: Input) -> Output {
        input.addBookmark.emitOnNext { [weak self] viewModel in
            guard let self else { return }
            let runtimeSource = documentState.runtimeEngine.source
            appDefaults.objectBookmarksBySourceAndImagePath[runtimeSource, default: [:]][imagePath, default: []].append(.init(source: runtimeSource, object: viewModel.runtimeObject))
        }
        .disposed(by: rx.disposeBag)

        input.searchStringForOpenQuickly
            .skip(1)
            .debounce(.milliseconds(500))
            .emitOnNextMainActor { [weak self] filter in
                guard let self else { return }
                if filter.isEmpty {
                    if isFilteringForOpenQuickly {
                        isFilteringForOpenQuickly = false
                    }
                    filteredNodesForOpenQuickly = []
                } else {
                    if !isFilteringForOpenQuickly {
                        isFilteringForOpenQuickly = true
                    }
                    Task.detached {
                        let filteredNodesForOpenQuickly = await FilterEngine.filter(filter, items: self.nodesForOpenQuickly, mode: .fuzzySearch, isCaseInsensitive: false)
                        await MainActor.run {
                            self.filteredNodesForOpenQuickly = filteredNodesForOpenQuickly
                        }
                    }
                }
            }
            .disposed(by: rx.disposeBag)

        input.runtimeObjectClickedForOpenQuickly
            .emitOnNextMainActor { [weak self] viewModel in
                guard let self else { return }
                #if os(macOS)
                documentState.selectionRouter.trigger(.selectAtRoot(viewModel.runtimeObject))
                #else
                self.router.trigger(.selectedObject(viewModel.runtimeObject))
                #endif
            }
            .disposed(by: rx.disposeBag)

        // Visual selection follows whatever the document is currently
        // inspecting at its root. The sidebar row click path already
        // dispatched `.selectAtRoot` through `documentState.selectionRouter`,
        // so observing `selectionStack` covers both that case (idempotent
        // re-select on the already-highlighted row) and the specialization-
        // completion case (new root object that has not yet been clicked).
        documentState.$selectionStack
            .asObservable()
            .compactMap { $0.first }
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

        return Output(
            runtimeObjectsForOpenQuickly: $filteredNodesForOpenQuickly.asDriver().skip(1),
            selectRuntimeObject: input.runtimeObjectClickedForOpenQuickly,
            selectCell: pendingResolved
        )
    }
}
