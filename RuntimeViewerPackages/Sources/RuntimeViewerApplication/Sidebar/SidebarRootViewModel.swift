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
    public private(set) var searchString: String = ""

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
        #if canImport(UIKit)
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
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        input.searchString.emit(with: self) {
            $0.nodes.first?.filter = $1
            $0.nodes = $0.nodes
        }.disposed(by: rx.disposeBag)
        return Output(
            nodes: $nodes.asDriver(),
            nodesIndexed: nodesIndexed,
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
