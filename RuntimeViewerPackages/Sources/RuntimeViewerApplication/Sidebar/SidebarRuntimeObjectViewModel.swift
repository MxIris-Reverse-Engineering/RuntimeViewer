import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

@Loggable(.private)
public class SidebarRuntimeObjectViewModel: ViewModel<SidebarRuntimeObjectRoute> {
    public let imageNode: RuntimeImageNode
    public let imagePath: String
    public let imageName: String
    public let runtimeEngine: RuntimeEngine

    var isSorted: Bool {
        false
    }

    @Observed public private(set) var loadState: RuntimeImageLoadState = .unknown
    @Observed public private(set) var searchString: String = ""
    @Observed public private(set) var nodes: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var filteredNodes: [SidebarRuntimeObjectCellViewModel] = []
    @Observed public private(set) var isFiltering: Bool = false
    @Observed public private(set) var isSearchCaseInsensitive: Bool = false
    @Observed public private(set) var loadingProgress: Double = 0
    @Observed public private(set) var loadingDescription: String = ""
    @Observed public private(set) var loadingItemCount: String = ""

    public init(imageNode: RuntimeImageNode, documentState: DocumentState, router: any Router<SidebarRuntimeObjectRoute>) {
        let imagePath = imageNode.path
        self.runtimeEngine = documentState.runtimeEngine
        self.imageNode = imageNode
        self.imagePath = imagePath
        self.imageName = imageNode.name
        super.init(documentState: documentState, router: router)

        runtimeEngine.reloadDataPublisher
            .asObservable()
            .subscribeOnNext { [weak self] in
                guard let self else { return }
                Task {
                    try await self.reloadData()
                }
            }
            .disposed(by: rx.disposeBag)

        Task {
            do {
                try await reloadData()
            } catch {
                self.loadState = .loadError(error)
                #log(.error, "\(error)")
            }
        }
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let runtimeObjectClicked: Signal<SidebarRuntimeObjectCellViewModel>
        public let loadImageClicked: Signal<Void>
        public let searchString: Driver<String>
        public let isSearchCaseInsensitive: Driver<Bool>
    }

    public struct Output {
        public let runtimeObjects: Driver<[SidebarRuntimeObjectCellViewModel]>
        public let loadState: Driver<RuntimeImageLoadState>
        public let notLoadedText: Driver<String>
        public let errorText: Driver<String>
        public let emptyText: Driver<String>
        public let isEmpty: Driver<Bool>
        public let loadingProgress: Driver<Double>
        public let loadingDescription: Driver<String>
        public let loadingItemCount: Driver<String>
        public let windowInitialTitles: Driver<(title: String, subtitle: String)>
        public let windowSubtitle: Signal<String>
        public let didBeginFiltering: Signal<Void>
        public let didChangeFiltering: Signal<Void>
        public let didEndFiltering: Signal<Void>
    }

    @MainActor
    public func transform(_ input: Input) -> Output {
//        input.isSearchCaseInsensitive.drive($isSearchCaseInsensitive).disposed(by: rx.disposeBag)

        Driver.combineLatest(input.searchString, input.isSearchCaseInsensitive)
            .debounce(.milliseconds(500))
            .driveOnNextMainActor { [weak self] searchString, isSearchCaseInsensitive in
                guard let self else { return }
                guard (self.searchString != searchString) || (self.isSearchCaseInsensitive != isSearchCaseInsensitive) else { return }

                self.searchString = searchString
                self.isSearchCaseInsensitive = isSearchCaseInsensitive

                if searchString.isEmpty {
                    if isFiltering {
                        isFiltering = false
                    }
                } else {
                    if !isFiltering {
                        isFiltering = true
                    }
                }
                filteredNodes = FilterEngine.filter(searchString, items: nodes, mode: appDefaults.filterMode, isCaseInsensitive: isSearchCaseInsensitive)
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
            loadingProgress: $loadingProgress.asDriver(),
            loadingDescription: $loadingDescription.asDriver(),
            loadingItemCount: $loadingItemCount.asDriver(),
            windowInitialTitles: .just((runtimeImageName, "")),
            windowSubtitle: input.runtimeObjectClicked.asSignal().map { "\($0.runtimeObject.displayName)" },
            didBeginFiltering: $isFiltering.asSignal(onErrorJustReturn: false).filter { $0 }.mapToVoid(),
            didChangeFiltering: $filteredNodes.asSignal(onErrorJustReturn: []).withLatestFrom($isFiltering.asSignal(onErrorJustReturn: false)).filter { $0 }.mapToVoid(),
            didEndFiltering: $isFiltering.skip(1).asSignal(onErrorJustReturn: false).filter { !$0 }.mapToVoid()
        )
    }

    func reloadData() async throws {
        let imageLoadState: RuntimeImageLoadState = try await runtimeEngine.isImageLoaded(path: imagePath) ? .loaded : .notLoaded

        if case .notLoaded = imageLoadState {
            await MainActor.run {
                self.loadState = .notLoaded
            }
            return
        }

        await MainActor.run {
            self.loadState = .loading
            self.loadingProgress = 0
            self.loadingDescription = "Preparing..."
            self.loadingItemCount = ""
        }

        var runtimeObjects: [RuntimeObject] = []
        for try await event in buildRuntimeObjectsStream() {
            switch event {
            case .progress(let progress):
                await MainActor.run {
                    self.loadingProgress = progress.overallFraction
                    self.loadingDescription = progress.phase.displayDescription
                    if progress.totalCount > 0 {
                        self.loadingItemCount = "\(progress.currentCount)/\(progress.totalCount)"
                    } else {
                        self.loadingItemCount = ""
                    }
                }
            case .completed(let result):
                runtimeObjects = result
            }
        }

        await MainActor.run {
            self.loadingProgress = 0.95
            self.loadingDescription = "Building list..."
            self.loadingItemCount = "\(runtimeObjects.count) objects"
        }

        await MainActor.run {
            self.loadState = .loaded
            self.loadingProgress = 1.0
            self.searchString = ""
            if isSorted {
                self.nodes = runtimeObjects.sorted().map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
            } else {
                self.nodes = runtimeObjects.map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
            }
            self.filteredNodes = self.nodes
        }
    }

    func buildRuntimeObjects() async throws -> [RuntimeObject] {
        []
    }

    func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let objects = try await self.buildRuntimeObjects()
                    continuation.yield(.completed(objects))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
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
