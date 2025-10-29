import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class SidebarImageViewModel: ViewModel<SidebarRoute> {
    private let namedNode: RuntimeNamedNode

    private let imagePath: String
    private let imageName: String

    private let runtimeEngine: RuntimeEngine

    @Observed private var searchString: String = ""
    @Observed private var searchScope: RuntimeTypeSearchScope = .all
    @Observed private var runtimeObjects: [RuntimeObjectName] = []
    @Observed private var filteredRuntimeObjects: [RuntimeObjectName] = []
    @Observed private var loadState: RuntimeImageLoadState = .unknown

    public init(node namedNode: RuntimeNamedNode, appServices: AppServices, router: any Router<SidebarRoute>) {
        self.runtimeEngine = appServices.runtimeEngine
        self.namedNode = namedNode
        let imagePath = namedNode.path
        self.imagePath = imagePath
        self.imageName = namedNode.name
        super.init(appServices: appServices, router: router)

        Task {
            do {
                let debouncedSearch = $searchString
                    .debounce(.milliseconds(80), scheduler: MainScheduler.instance)
                    .asObservable()

                debouncedSearch
                    .withLatestFrom($runtimeObjects.asObservable()) { (searchString: String, runtimeObjects: [RuntimeObjectName]) -> [RuntimeObjectName] in
                        if searchString.isEmpty {
                            return runtimeObjects.sorted()
                        } else {
                            return runtimeObjects.filter { $0.name.localizedCaseInsensitiveContains(searchString) }.sorted()
                        }
                    }
                    .bind(to: $filteredRuntimeObjects)
                    .disposed(by: rx.disposeBag)

                await runtimeEngine.reloadDataPublisher
                    .asObservable()
                    .subscribeOnNext { [weak self] in
                        guard let self else { return }
                        Task {
                            try await self.reloadData()
                        }
                    }
                    .disposed(by: rx.disposeBag)

//                await runtimeEngine.$imageList
//                    .asObservable()
//                    .flatMap { [unowned self] imageList in
//                        try imageList.contains(await runtimeEngine.patchImagePathForDyld(imagePath))
//                    }
//                    .catchAndReturn(false)
//                    .filter { $0 } // only allow isLoaded to pass through; we don't want to erase an existing state
//                    .map { _ in RuntimeImageLoadState.loaded }
//                    .observeOnMainScheduler()
//                    .bind(to: $loadState)
//                    .disposed(by: rx.disposeBag)

                try await reloadData()
            } catch {
                self.loadState = .loadError(error)
                print(error)
            }
        }
    }

    public struct Input {
        public let runtimeObjectClicked: Signal<SidebarImageCellViewModel>
        public let loadImageClicked: Signal<Void>
        public let searchString: Signal<String>
        public init(runtimeObjectClicked: Signal<SidebarImageCellViewModel>, loadImageClicked: Signal<Void>, searchString: Signal<String>) {
            self.runtimeObjectClicked = runtimeObjectClicked
            self.loadImageClicked = loadImageClicked
            self.searchString = searchString
        }
    }

    public struct Output {
        public let runtimeObjects: Driver<[SidebarImageCellViewModel]>
        public let loadState: Driver<RuntimeImageLoadState>
        public let notLoadedText: Driver<String>
        public let errorText: Driver<String>
        public let emptyText: Driver<String>
        public let isEmpty: Driver<Bool>
        public let windowInitialTitles: Driver<(title: String, subtitle: String)>
        public let windowSubtitle: Signal<String>
    }

    private func reloadData() async throws {
        let loadState: RuntimeImageLoadState = try await runtimeEngine.isImageLoaded(path: imagePath) ? .loaded : .notLoaded
        if case .notLoaded = loadState {
            await MainActor.run {
                self.loadState = loadState
            }
            return
        }
        await MainActor.run {
            self.loadState = .loading
        }
        let names = try await runtimeEngine.names(in: imagePath)
        await MainActor.run {
            let searchString = ""
            let searchScope: RuntimeTypeSearchScope = .all

            self.searchString = searchString
            self.searchScope = searchScope

            self.runtimeObjects = names.sorted()
            self.filteredRuntimeObjects = self.runtimeObjects

            self.loadState = loadState
        }
    }

    @MainActor
    public func transform(_ input: Input) -> Output {
        input.searchString.emit(to: $searchString).disposed(by: rx.disposeBag)

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

        let runtimeObjects = $filteredRuntimeObjects.asDriver()
            .map {
                $0.map { SidebarImageCellViewModel(runtimeObject: $0, parent: nil) }
            }

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
        let runtimeNodeName = namedNode.name
        return Output(
            runtimeObjects: runtimeObjects,
            loadState: $loadState.asDriver(),
            notLoadedText: .just("\(imageName) is not yet loaded"),
            errorText: errorText,
            emptyText: .just("\(imageName) is loaded however does not appear to contain any classes or protocols"),
            isEmpty: $runtimeObjects.asDriver().map { $0.isEmpty },
            windowInitialTitles: .just((runtimeNodeName, "")),
            windowSubtitle: input.runtimeObjectClicked.asSignal().map { "\($0.runtimeObject.name)" }
        )
    }

    private static func runtimeObjectsFor(classNames: [String], protocolNames: [String], searchString: String, searchScope: RuntimeTypeSearchScope) -> [RuntimeObjectType] {
        var ret: [RuntimeObjectType] = []
        if searchScope.includesClasses {
            ret += classNames.map { .class(named: $0) }
        }
        if searchScope.includesProtocols {
            ret += protocolNames.map { .protocol(named: $0) }
        }
        if searchString.isEmpty { return ret }
        return ret.filter { $0.name.localizedCaseInsensitiveContains(searchString) }
    }

    private func tryLoadImage() {
        Task {
            do {
                await MainActor.run {
                    loadState = .loading
                }
                try await runtimeEngine.loadImage(at: imagePath)
                await MainActor.run {
                    loadState = .loaded
                }
            } catch {
                await MainActor.run {
                    loadState = .loadError(error)
                }
            }
        }
    }
}
