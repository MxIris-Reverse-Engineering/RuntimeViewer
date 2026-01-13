import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Ifrit
import MemberwiseInit

public class SidebarRootViewModel: ViewModel<SidebarRootRoute> {
    private let nodesSource: Observable<[RuntimeImageNode]>

    private var nodesIndexed: Signal<Void> = .empty()

    var isFilterEmptyNodes: Bool { true }

    @Observed
    public private(set) var nodes: [SidebarRootCellViewModel] = []

    @Observed
    public private(set) var filteredNodes: [SidebarRootCellViewModel] = []

    @Observed
    public private(set) var allNodes: [String: SidebarRootCellViewModel] = [:]

    @Observed
    public private(set) var isFiltering: Bool = false

    public init(appServices: AppServices, router: any Router<SidebarRootRoute>, nodesSource: Observable<[RuntimeImageNode]>) {
        self.nodesSource = nodesSource

        super.init(appServices: appServices, router: router)

        nodesSource
            .observe(on: MainScheduler.instance)
            .map { $0.map { SidebarRootCellViewModel(node: $0, parent: nil) } }
            .bind(to: $nodes)
            .disposed(by: rx.disposeBag)

        let indexedNodes = $nodes
            .filter { [weak self] in
                guard let self else { return false }
                return isFilterEmptyNodes ? !$0.isEmpty : true
            }
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInteractive))
            .flatMapLatest { nodes -> [String: SidebarRootCellViewModel] in
                var allNodes: [String: SidebarRootCellViewModel] = [:]
                for rootNode in nodes {
                    allNodes[rootNode.node.name] = rootNode
                    let rootNodeSequence = AnySequence<SidebarRootCellViewModel> {
                        SidebarRootCellViewModel.Iterator(node: rootNode)
                    }
                    for node in rootNodeSequence {
                        allNodes[node.node.absolutePath] = node
                    }
                }
                return allNodes
            }
            .observe(on: MainScheduler.instance)
            .asSignal(onErrorJustReturn: [:])

        indexedNodes.emit(to: $allNodes).disposed(by: rx.disposeBag)

        self.nodesIndexed = indexedNodes.trackActivity(_commonLoading).asSignal().mapToVoid()
        
        
        $nodes
            .bind(to: $filteredNodes)
            .disposed(by: rx.disposeBag)
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let clickedNode: Signal<SidebarRootCellViewModel>
        public let selectedNode: Signal<SidebarRootCellViewModel>
        public let searchString: Signal<String>
    }

    @MemberwiseInit(.public)
    public struct Output {
        public let nodes: Driver<[SidebarRootCellViewModel]>
        public let nodesIndexed: Signal<Void>
        public let didBeginFiltering: Signal<Void>
        public let didChangeFiltering: Signal<Void>
        public let didEndFiltering: Signal<Void>
    }

    public func transform(_ input: Input) -> Output {
        input.clickedNode.emitOnNextMainActor { [weak self] viewModel in
            guard let self = self else { return }

            if viewModel.node.isLeaf {
                #if os(macOS)
                self.router.trigger(.image(viewModel.node))
                #else
                self.router.trigger(.clickedNode(viewModel.node))
                #endif
            }
        }
        .disposed(by: rx.disposeBag)

        input.searchString
            .debounce(.milliseconds(500))
            .emitOnNextMainActor { [weak self] filter in
                guard let self else { return }
                for node in nodes {
                    node.filter = filter
                }
                if filter.isEmpty {
                    if isFiltering {
                        isFiltering = false
                    }
                    filteredNodes = nodes
                } else {
                    if !isFiltering {
                        isFiltering = true
                    }
                    filteredNodes = nodes.filter { $0.currentAndChildrenNames.localizedCaseInsensitiveContains(filter) }
                }
            }.disposed(by: rx.disposeBag)

        return Output(
            nodes: $filteredNodes.asDriver(),
            nodesIndexed: nodesIndexed,
            didBeginFiltering: $isFiltering.asSignal(onErrorJustReturn: false).filter { $0 }.mapToVoid(),
            didChangeFiltering: $filteredNodes.asSignal(onErrorJustReturn: []).withLatestFrom($isFiltering.asSignal(onErrorJustReturn: false)).filter { $0 }.mapToVoid(),
            didEndFiltering: $isFiltering.skip(1).asSignal(onErrorJustReturn: false).filter { !$0 }.mapToVoid()
        )
    }
}

extension Collection {
    fileprivate var isNotEmpty: Bool { !isEmpty }
}
