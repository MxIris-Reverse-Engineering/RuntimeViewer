#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures

public class SidebarImageViewModel: ViewModel<SidebarRoute> {
    private let namedNode: RuntimeNamedNode

    private let imagePath: String
    private let imageName: String

    private let runtimeListings: RuntimeListings

    @Observed private var searchString: String = ""
    @Observed private var searchScope: RuntimeTypeSearchScope = .all
    @Observed private var classNames: [String] = []
    @Observed private var protocolNames: [String] = []
    @Observed private var runtimeObjects: [RuntimeObjectType] = []
    @Observed private var loadState: RuntimeImageLoadState = .notLoaded

    public init(node namedNode: RuntimeNamedNode, appServices: AppServices, router: any Router<SidebarRoute>) {
        self.runtimeListings = appServices.runtimeListings
        self.namedNode = namedNode
        let imagePath = namedNode.path
        self.imagePath = imagePath
        self.imageName = namedNode.name
        super.init(appServices: appServices, router: router)
        Task {
            let classNames = try await runtimeListings.classNamesIn(image: imagePath)
            let protocolNames = try runtimeListings.imageToProtocols[await runtimeListings.patchImagePathForDyld(imagePath)] ?? []
            let loadState: RuntimeImageLoadState = try await runtimeListings.isImageLoaded(path: imagePath) ? .loaded : .notLoaded
            await MainActor.run {
                self.classNames = classNames
                self.protocolNames = protocolNames

                let searchString = ""
                let searchScope: RuntimeTypeSearchScope = .all

                self.searchString = searchString
                self.searchScope = searchScope

                self.runtimeObjects = Self.runtimeObjectsFor(
                    classNames: classNames, protocolNames: protocolNames,
                    searchString: searchString, searchScope: searchScope
                )

                self.loadState = loadState
            }

            runtimeListings.$classList
                .asObservable()
                .flatMap { [unowned self] _ in
                    try await runtimeListings.classNamesIn(image: imagePath)
                }
                .catchAndReturn([])
                .observeOnMainScheduler()
                .bind(to: $classNames)
                .disposed(by: rx.disposeBag)

            runtimeListings.$imageToProtocols
                .asObservable()
                .flatMap { [unowned self] imageToProtocols in
                    try imageToProtocols[await runtimeListings.patchImagePathForDyld(imagePath)] ?? []
                }
                .catchAndReturn([])
                .observeOnMainScheduler()
                .bind(to: $protocolNames)
                .disposed(by: rx.disposeBag)

            let debouncedSearch = $searchString
                .debounce(.milliseconds(80), scheduler: MainScheduler.instance)
                .asObservable()

            $searchScope
                .asPublisher()
                .combineLatest(debouncedSearch.asPublisher(), $classNames.asPublisher(), $protocolNames.asPublisher()) {
                    Self.runtimeObjectsFor(
                        classNames: $2, protocolNames: $3,
                        searchString: $1, searchScope: $0
                    )
                }
                .asObservable()
                .map { $0.sorted() }
                .bind(to: $runtimeObjects)
                .disposed(by: rx.disposeBag)

            runtimeListings.$imageList
                .asObservable()
                .flatMap { [unowned self] imageList in
                    try imageList.contains(await runtimeListings.patchImagePathForDyld(imagePath))
                }
                .catchAndReturn(false)
                .filter { $0 } // only allow isLoaded to pass through; we don't want to erase an existing state
                .map { _ in RuntimeImageLoadState.loaded }
                .observeOnMainScheduler()
                .bind(to: $loadState)
                .disposed(by: rx.disposeBag)
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

        let runtimeObjects = $runtimeObjects.asDriver()
            .map {
                $0.map { SidebarImageCellViewModel(runtimeObject: $0) }
            }

        let errorText = $loadState
            .capture(case: RuntimeImageLoadState.loadError).map { [weak self] error in
                guard let self else { return "" }
                if let dlOpenError = error as? DlOpenError, let message = dlOpenError.message {
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
            isEmpty: .combineLatest($classNames.asDriver(), $protocolNames.asDriver(), resultSelector: { $0.isEmpty && $1.isEmpty }).startWith(classNames.isEmpty && protocolNames.isEmpty),
            windowInitialTitles: .combineLatest($classNames.asDriver(), $protocolNames.asDriver(), resultSelector: { (runtimeNodeName, "Classes: \($0.count) Protocols: \($1.count)") }),
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
                try await runtimeListings.loadImage(at: imagePath)
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
