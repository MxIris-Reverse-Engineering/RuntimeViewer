import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public final class SidebarImageViewModel: ViewModel<SidebarRoute> {
    public let imageNode: RuntimeImageNode
    public let imagePath: String
    public let imageName: String
    public let runtimeEngine: RuntimeEngine

    @Observed public private(set) var loadState: RuntimeImageLoadState = .unknown
    @Observed public private(set) var searchString: String = ""
    @Observed public private(set) var searchStringForOpenQuickly: String = ""
    @Observed public private(set) var nodes: [SidebarImageCellViewModel] = []
    @Observed public private(set) var nodesForOpenQuickly: [SidebarImageCellViewModel] = []
    @Observed public private(set) var filteredNodes: [SidebarImageCellViewModel] = []
    @Observed public private(set) var filteredNodesForOpenQuickly: [SidebarImageCellViewModel] = []
    @Observed public private(set) var isFiltering: Bool = false
    @Observed public private(set) var isFilteringForOpenQuickly: Bool = false

    public init(node imageNode: RuntimeImageNode, appServices: AppServices, router: any Router<SidebarRoute>) {
        self.runtimeEngine = appServices.runtimeEngine
        self.imageNode = imageNode
        let imagePath = imageNode.path
        self.imagePath = imagePath
        self.imageName = imageNode.name
        super.init(appServices: appServices, router: router)

        Task {
            do {
                await runtimeEngine.reloadDataPublisher
                    .asObservable()
                    .subscribeOnNext { [weak self] in
                        guard let self else { return }
                        Task {
                            try await self.reloadData()
                        }
                    }
                    .disposed(by: rx.disposeBag)
                try await reloadData()
            } catch {
                self.loadState = .loadError(error)
                print(error)
            }
        }
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let runtimeObjectClicked: Signal<SidebarImageCellViewModel>
//        public let runtimeObjectClickedForOpenQuickly: Signal<SidebarImageCellViewModel>
        public let loadImageClicked: Signal<Void>
        public let searchString: Signal<String>
        public let searchStringForOpenQuickly: Signal<String>
    }

    public struct Output {
        public let runtimeObjects: Driver<[SidebarImageCellViewModel]>
        public let runtimeObjectsForOpenQuickly: Driver<[SidebarImageCellViewModel]>
        public let loadState: Driver<RuntimeImageLoadState>
        public let notLoadedText: Driver<String>
        public let errorText: Driver<String>
        public let emptyText: Driver<String>
        public let isEmpty: Driver<Bool>
        public let windowInitialTitles: Driver<(title: String, subtitle: String)>
        public let windowSubtitle: Signal<String>
        public let didBeginFiltering: Signal<Void>
        public let didChangeFiltering: Signal<Void>
        public let didEndFiltering: Signal<Void>
    }

    private func reloadData() async throws {
        let loadState: RuntimeImageLoadState = try await runtimeEngine.isImageLoaded(path: imagePath) ? .loaded : .notLoaded
        if case .notLoaded = loadState {
            await MainActor.run {
                self.loadState = .notLoaded
            }
            return
        }
        await MainActor.run {
            self.loadState = .loading
        }
        let names = try await runtimeEngine.names(in: imagePath)
        await MainActor.run {
            self.loadState = .loaded
            self.searchString = ""
            self.searchStringForOpenQuickly = ""
            self.nodes = names.sorted().map { SidebarImageCellViewModel(runtimeObject: $0, parent: nil, forOpenQuickly: false) }
            self.nodesForOpenQuickly = names.sorted().map { SidebarImageCellViewModel(runtimeObject: $0, parent: nil, forOpenQuickly: true) }
            self.filteredNodes = self.nodes
            self.filteredNodesForOpenQuickly = self.nodesForOpenQuickly
        }
    }

    @MainActor
    public func transform(_ input: Input) -> Output {
        input.searchString
            .debounce(.milliseconds(80))
            .emitOnNextMainActor { [weak self] filter in
                guard let self else { return }
                if filter.isEmpty {
                    if isFiltering {
                        isFiltering = false
                    }
                } else {
                    if !isFiltering {
                        isFiltering = true
                    }
                }
                filteredNodes = FilterEngine.filter(filter, items: nodes, mode: appDefaults.filterMode)
            }
            .disposed(by: rx.disposeBag)
        
        input.searchStringForOpenQuickly
            .debounce(.milliseconds(80))
            .emitOnNextMainActor { [weak self] filter in
                guard let self else { return }
                if filter.isEmpty {
                    if isFilteringForOpenQuickly {
                        isFilteringForOpenQuickly = false
                    }
                } else {
                    if !isFilteringForOpenQuickly {
                        isFilteringForOpenQuickly = true
                    }
                }
                filteredNodesForOpenQuickly = FilterEngine.filter(filter, items: nodesForOpenQuickly, mode: appDefaults.filterMode)
            }
            .disposed(by: rx.disposeBag)

        input.runtimeObjectClicked.emitOnNextMainActor { [weak self] viewModel in
            guard let self else { return }
            self.router.trigger(.selectedObject(viewModel.runtimeObject))
        }
        .disposed(by: rx.disposeBag)

        input.loadImageClicked.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            tryLoadImage()
        }
        .disposed(by: rx.disposeBag)

        let errorText = $loadState
            .capture(case: RuntimeImageLoadState.loadError).map { [weak self] error in
                guard let self else { return "" }
                if let dyldOpenError = error as? DyldOpenError, let message = dyldOpenError.message {
                    return message
                } else {
                    return "An unknown error occured trying to load '\(imagePath)'"
                }
            }
            .asDriver(onErrorJustReturn: "")
        let runtimeImageName = imageNode.name
        return Output(
            runtimeObjects: $filteredNodes.asDriver(),
            runtimeObjectsForOpenQuickly: $filteredNodesForOpenQuickly.asDriver(),
            loadState: $loadState.asDriver(),
            notLoadedText: .just("\(imageName) is not yet loaded"),
            errorText: errorText,
            emptyText: .just("\(imageName) is loaded however does not appear to contain any classes or protocols"),
            isEmpty: $nodes.asDriver().map { $0.isEmpty },
            windowInitialTitles: .just((runtimeImageName, "")),
            windowSubtitle: input.runtimeObjectClicked.asSignal().map { "\($0.runtimeObject.displayName)" },
            didBeginFiltering: $isFiltering.asSignal(onErrorJustReturn: false).filter { $0 }.mapToVoid(),
            didChangeFiltering: input.searchString.withLatestFrom($isFiltering.asSignal(onErrorJustReturn: false)) { !$0.isEmpty && $1 }.filter { $0 }.mapToVoid(),
            didEndFiltering: $isFiltering.skip(1).asSignal(onErrorJustReturn: false).filter { !$0 }.mapToVoid()
        )
    }

    private func tryLoadImage() {
        Task { @MainActor in
            do {
                loadState = .loading
                try await runtimeEngine.loadImage(at: imagePath)
                loadState = .loaded

            } catch {
                loadState = .loadError(error)
            }
        }
    }
}
