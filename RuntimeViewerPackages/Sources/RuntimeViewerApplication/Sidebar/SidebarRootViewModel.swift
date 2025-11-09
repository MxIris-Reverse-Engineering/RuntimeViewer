import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class SidebarRootViewModel: ViewModel<SidebarRoute> {
    @Observed
    public private(set) var nodes: [SidebarRootCellViewModel] = []

    @Observed
    public private(set) var filteredNodes: [SidebarRootCellViewModel]? = nil

    @Observed
    public private(set) var allNodes: [String: SidebarRootCellViewModel] = [:]

    @Observed
    public private(set) var isFiltering: Bool = false

    private var nodesIndexed: Signal<Void> = .empty()

    public override init(appServices: AppServices, router: any Router<SidebarRoute>) {
        super.init(appServices: appServices, router: router)
        let indexedNodes = $nodes
            .filter { !$0.isEmpty }
            .observe(on: ConcurrentDispatchQueueScheduler(qos: .userInteractive))
            .flatMapLatest { nodes -> [String: SidebarRootCellViewModel] in
                var allNodes: [String: SidebarRootCellViewModel] = [:]
                for rootNode in nodes {
                    allNodes[rootNode.node.name] = rootNode
                    for node in rootNode {
                        allNodes[node.node.absolutePath] = node
                    }
                }
                return allNodes
            }
            .observe(on: MainScheduler.instance)
            .asSignal(onErrorJustReturn: [:])

        indexedNodes.emit(to: $allNodes).disposed(by: rx.disposeBag)

        self.nodesIndexed = indexedNodes.trackActivity(_commonLoading).asSignal().mapToVoid()

        Task {
            await appServices.runtimeEngine.$imageNodes
                .asObservable()
                .observe(on: MainScheduler.instance)
                .map { $0.map { SidebarRootCellViewModel(node: $0, parent: nil) } }
                .bind(to: $nodes)
                .disposed(by: rx.disposeBag)
        }
        
//        $nodes.asObservable()
//            .subscribeOnNext { _ in
//                print("nodes reload")
//            }
//            .disposed(by: rx.disposeBag)
//        
//        nodesIndexed.asObservable()
//            .subscribeOnNext { _ in
//                print("nodes indexed")
//            }
//            .disposed(by: rx.disposeBag)
    }

    public struct Input {
        public let clickedNode: Signal<SidebarRootCellViewModel>
        public let selectedNode: Signal<SidebarRootCellViewModel>
        public let searchString: Signal<String>
        public init(clickedNode: Signal<SidebarRootCellViewModel>, selectedNode: Signal<SidebarRootCellViewModel>, searchString: Signal<String>) {
            self.clickedNode = clickedNode
            self.selectedNode = selectedNode
            self.searchString = searchString
        }
    }

    public struct Output {
        public let nodes: Driver<[SidebarRootCellViewModel]>
        public let nodesIndexed: Signal<Void>
        #if os(macOS)
        public let didBeginFiltering: Signal<Void>
        public let didChangeFiltering: Signal<Void>
        public let didEndFiltering: Signal<Void>
        #else
        public let filteredNodes: Driver<[SidebarRootCellViewModel]?>
        #endif
    }

    public func transform(_ input: Input) -> Output {
        input.clickedNode.emitOnNextMainActor { [weak self] viewModel in
            guard let self = self else { return }

            if viewModel.node.isLeaf {
                self.router.trigger(.clickedNode(viewModel.node))
            }
        }
        .disposed(by: rx.disposeBag)
        #if os(macOS)
        input.searchString.emit(with: self) {
            for node in $0.nodes {
                node.filter = $1
            }
            $0.nodes = $0.nodes
            if $1.isEmpty {
                if $0.isFiltering {
                    $0.isFiltering = false
                }
            } else {
                if !$0.isFiltering {
                    $0.isFiltering = true
                }
            }
        }.disposed(by: rx.disposeBag)
        return Output(
            nodes: $nodes.asDriver(),
            nodesIndexed: nodesIndexed,
            didBeginFiltering: $isFiltering.asSignal(onErrorJustReturn: false).filter { $0 }.mapToVoid(),
            didChangeFiltering: input.searchString.mapToVoid(),
            didEndFiltering: $isFiltering.asSignal(onErrorJustReturn: false).filter { !$0 }.mapToVoid(),
        )
        #endif

        #if canImport(UIKit)

//        input.searchString.emit(with: self) { target, searchString in
//            if searchString.isEmpty {
//                target.filteredNodes = nil
//            } else {
//                let rootNode = [SidebarRootCellViewModel(node: CDUtilities.dyldSharedCacheImageRootNode, parent: nil)]
//                rootNode.filter = searchString
//                target.filteredNodes = rootNode
//            }
//        }.disposed(by: rx.disposeBag)

        return Output(nodes: $nodes.asDriver(), nodesIndexed: nodesIndexed, filteredNodes: $filteredNodes.asDriver())

        #endif
    }
}
