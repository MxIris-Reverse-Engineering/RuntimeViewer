import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public final class SidebarRuntimeObjectListViewModel: SidebarRuntimeObjectViewModel, @unchecked Sendable {
    private let openQuicklySearchQueue: DispatchQueue

    @Observed public private(set) var searchStringForOpenQuickly: String = ""
    @Observed public private(set) var nodesForOpenQuickly: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var filteredNodesForOpenQuickly: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var isFilteringForOpenQuickly: Bool = false

    public override init(imageNode: RuntimeImageNode, documentState: DocumentState, router: any Router<SidebarRuntimeObjectRoute>) {
        self.openQuicklySearchQueue = DispatchQueue(label: "com.MxIris.RuntimeViewerApplication.\(Self.self)")
        super.init(imageNode: imageNode, documentState: documentState, router: router)
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
    }
    
    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        try await runtimeEngine.objects(in: imagePath)
    }

    override func reloadData() async throws {
        try await super.reloadData()

        await MainActor.run {
            self.searchStringForOpenQuickly = ""
            self.nodesForOpenQuickly = nodes.map { $0.runtimeObject }.sorted().map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, parent: nil, forOpenQuickly: true) }
            self.filteredNodesForOpenQuickly = []
        }
    }

    @MainActor
    public func transform(_ input: Input) -> Output {
        
        input.addBookmark.emitOnNext { [weak self] viewModel in
            guard let self else { return }
            
            appDefaults.objectBookmarks.append(.init(source: documentState.runtimeEngine.source, object: viewModel.runtimeObject))
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
                    openQuicklySearchQueue.async {
                        self.filteredNodesForOpenQuickly = FilterEngine.filter(filter, items: self.nodesForOpenQuickly, mode: .fuzzySearch, isCaseInsensitive: false)
                    }
                }
            }
            .disposed(by: rx.disposeBag)

        input.runtimeObjectClickedForOpenQuickly
            .emitOnNextMainActor { [weak self] viewModel in
                guard let self else { return }
                self.router.trigger(.selectedObject(viewModel.runtimeObject))
            }
            .disposed(by: rx.disposeBag)

        return Output(
            runtimeObjectsForOpenQuickly: $filteredNodesForOpenQuickly.asDriver().skip(1),
            selectRuntimeObject: input.runtimeObjectClickedForOpenQuickly
        )
    }
}
