//
//  SidebarImageViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures

class SidebarImageViewModel: ViewModel<SidebarRoute> {
    public let namedNode: RuntimeNamedNode

    public let imagePath: String
    public let imageName: String

    public let runtimeListings: RuntimeListings = .shared

    @Observed public private(set) var searchString: String
    @Observed public private(set) var searchScope: RuntimeTypeSearchScope
    @Observed public private(set) var classNames: [String] // not filtered
    @Observed public private(set) var protocolNames: [String] // not filtered
    @Observed public private(set) var runtimeObjects: [RuntimeObjectType] // filtered based on search
    @Observed public private(set) var loadState: RuntimeImageLoadState

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

    public init(node namedNode: RuntimeNamedNode, appServices: AppServices, router: UnownedRouter<SidebarRoute>) {
        self.namedNode = namedNode
        let imagePath = namedNode.path
        self.imagePath = imagePath
        self.imageName = namedNode.name

        let classNames = CDUtilities.classNamesIn(image: imagePath)
        let protocolNames = runtimeListings.imageToProtocols[CDUtilities.patchImagePathForDyld(imagePath)] ?? []
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

        self.loadState = runtimeListings.isImageLoaded(path: imagePath) ? .loaded : .notLoaded

        super.init(appServices: appServices, router: router)

        runtimeListings.$classList
            .map { _ in
                CDUtilities.classNamesIn(image: imagePath)
            }
            .asObservable()
            .bind(to: $classNames)
            .disposed(by: rx.disposeBag)

        runtimeListings.$imageToProtocols
            .map { imageToProtocols in
                imageToProtocols[CDUtilities.patchImagePathForDyld(imagePath)] ?? []
            }
            .asObservable()
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
            .bind(to: $runtimeObjects)
            .disposed(by: rx.disposeBag)

        runtimeListings.$imageList
            .map { imageList in
                imageList.contains(CDUtilities.patchImagePathForDyld(imagePath))
            }
            .filter { $0 } // only allow isLoaded to pass through; we don't want to erase an existing state
            .map { _ in
                RuntimeImageLoadState.loaded
            }
            .asObservable()
            .bind(to: $loadState)
            .disposed(by: rx.disposeBag)
    }

    public func tryLoadImage() {
        do {
            loadState = .loading
            try CDUtilities.loadImage(at: imagePath)
            // we could set .loaded here, but there are already pipelines that will update the state
        } catch {
            loadState = .loadError(error)
        }
    }
    
    struct Input {
        let clickedRuntimeObject: Signal<SidebarImageCellViewModel>
    }
    
    struct Output {
        let runtimeObjects: Driver<[SidebarImageCellViewModel]>
    }
    
    func transform(_ input: Input) -> Output {
        
        input.clickedRuntimeObject.emitOnNextMainActor { [weak self] viewModel in
            guard let self else { return }
            self.router.trigger(.selectedObject(viewModel.runtimeObject))
        }
        .disposed(by: rx.disposeBag)
        
        return Output(runtimeObjects: $runtimeObjects.asDriver().map {
            $0.compactMap { [weak self] in
                guard let self else { return nil }
                return SidebarImageCellViewModel(runtimeObject: $0, appServices: appServices, router: router)
            }
        })
    }
}

class SidebarImageCellViewModel: ViewModel<SidebarRoute>, Differentiable {
    let runtimeObject: RuntimeObjectType
    
    @Observed
    var icon: NSImage?
    
    @Observed
    var name: NSAttributedString
    
    init(runtimeObject: RuntimeObjectType, appServices: AppServices, router: UnownedRouter<SidebarRoute>) {
        self.runtimeObject = runtimeObject
        switch runtimeObject {
        case .class:
            self.icon = IDEIcon("C", color: .yellow).image
        case .protocol:
            self.icon = IDEIcon("P", color: .purple).image
        }
        self.name = NSAttributedString {
            AText(runtimeObject.name)
                .font(.systemFont(ofSize: 13))
                .foregroundColor(.labelColor)
        }
        super.init(appServices: appServices, router: router)
    }
    
    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(runtimeObject)
        return hasher.finalize()
    }
    
    override func isEqual(to object: Any?) -> Bool {
        guard let object = object as? Self else { return false }
        return runtimeObject == object.runtimeObject
    }
}
