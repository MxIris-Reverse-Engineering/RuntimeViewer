import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

public class SidebarRuntimeObjectViewModel: ViewModel<SidebarRuntimeObjectRoute> {
    public let imageNode: RuntimeImageNode
    public let imagePath: String
    public let imageName: String
    public let runtimeEngine: RuntimeEngine

    @Observed public private(set) var loadState: RuntimeImageLoadState = .unknown
    @Observed public private(set) var searchString: String = ""
    @Observed public private(set) var nodes: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var filteredNodes: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var isFiltering: Bool = false
    @Observed public private(set) var isSearchCaseInsensitive: Bool = false

    public init(imageNode: RuntimeImageNode, documentState: DocumentState, router: any Router<SidebarRuntimeObjectRoute>) {
        let imagePath = imageNode.path
        self.runtimeEngine = documentState.runtimeEngine
        self.imageNode = imageNode
        self.imagePath = imagePath
        self.imageName = imageNode.name
        super.init(documentState: documentState, router: router)

        Task {
            await runtimeEngine.reloadDataPublisher
                .asObservable()
                .subscribeOnNext { [weak self] in
                    guard let self else { return }
                    Task {
                        try await self.reloadData()
                    }
                }
                .disposed(by: rx.disposeBag)
            
            do {
                try await reloadData()
            } catch {
                self.loadState = .loadError(error)
                logger.error("\(error)")
            }
        }
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let runtimeObjectClicked: Signal<SidebarRuntimeObjectCellViewModel>
        public let loadImageClicked: Signal<Void>
        public let searchString: Signal<String>
        public let isSearchCaseInsensitive: Driver<Bool>?
    }

    public struct Output {
        public let runtimeObjects: Driver<[SidebarRuntimeObjectCellViewModel]>
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

    @MainActor
    public func transform(_ input: Input) -> Output {
        input.isSearchCaseInsensitive?.drive($isSearchCaseInsensitive).disposed(by: rx.disposeBag)

        input.searchString
            .debounce(.milliseconds(500))
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
                filteredNodes = FilterEngine.filter(filter, items: nodes, mode: appDefaults.filterMode, isCaseInsensitive: isSearchCaseInsensitive)
            }
            .disposed(by: rx.disposeBag)

        input.runtimeObjectClicked
            .emitOnNextMainActor { [weak self] viewModel in
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

        let distinctLoadState = $loadState.asObservable()
            .distinctUntilChanged()
            .flatMapLatest { state -> Observable<RuntimeImageLoadState> in
                switch state {
                case .loading:
                    return Observable.just(state)
                        .delay(.milliseconds(500), scheduler: MainScheduler.instance)
                default:
                    return Observable.just(state)
                }
            }
            .asDriver(onErrorDriveWith: .empty())

        return Output(
            runtimeObjects: $filteredNodes.asDriver(),
            loadState: distinctLoadState,
            notLoadedText: .just("\(imageName) is not yet loaded"),
            errorText: errorText,
            emptyText: .just("\(imageName) is loaded however does not appear to contain any classes or protocols"),
            isEmpty: $nodes.asDriver().map { $0.isEmpty },
            windowInitialTitles: .just((runtimeImageName, "")),
            windowSubtitle: input.runtimeObjectClicked.asSignal().map { "\($0.runtimeObject.displayName)" },
            didBeginFiltering: $isFiltering.asSignal(onErrorJustReturn: false).filter { $0 }.mapToVoid(),
            didChangeFiltering: $filteredNodes.asSignal(onErrorJustReturn: []).withLatestFrom($isFiltering.asSignal(onErrorJustReturn: false)).filter { $0 }.mapToVoid(),
            didEndFiltering: $isFiltering.skip(1).asSignal(onErrorJustReturn: false).filter { !$0 }.mapToVoid()
        )
    }

    func reloadData() async throws {
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

        let runtimeObjects = try await buildRuntimeObjects()

        await MainActor.run {
            self.loadState = .loaded
            self.searchString = ""
            self.nodes = runtimeObjects.sorted().map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, parent: nil, forOpenQuickly: false) }
            self.filteredNodes = self.nodes
        }
    }

    func buildRuntimeObjects() async throws -> [RuntimeObject] { [] }

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

extension RuntimeImageLoadState: @retroactive Equatable {
    public static func == (lhs: RuntimeViewerCore.RuntimeImageLoadState, rhs: RuntimeViewerCore.RuntimeImageLoadState) -> Bool {
        switch (lhs, rhs) {
        case (.unknown, .unknown): return true
        case (.loaded, .loaded): return true
        case (.loading, .loading): return true
        case (.notLoaded, .notLoaded): return true
        case (.loadError, .loadError): return true
        default: return false
        }
    }
}
