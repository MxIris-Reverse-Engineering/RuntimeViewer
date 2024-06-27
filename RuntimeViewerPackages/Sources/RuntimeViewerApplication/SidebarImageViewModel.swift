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

    
    @MainActor @Observed private var searchString: String = ""
    @MainActor @Observed private var searchScope: RuntimeTypeSearchScope = .all
    @MainActor @Observed private var classNames: [String] = []
    @MainActor @Observed private var protocolNames: [String] = []
    @MainActor @Observed private var runtimeObjects: [RuntimeObjectType] = []
    @MainActor @Observed private var loadState: RuntimeImageLoadState = .notLoaded

    
    public init(node namedNode: RuntimeNamedNode, appServices: AppServices, router: any Router<SidebarRoute>) {
        self.runtimeListings = appServices.runtimeListings
        self.namedNode = namedNode
        let imagePath = namedNode.path
        self.imagePath = imagePath
        self.imageName = namedNode.name
        super.init(appServices: appServices, router: router)
        Task {

            let classNames = try await runtimeListings.classNamesIn(image: imagePath)
            let protocolNames = runtimeListings.imageToProtocols[try await runtimeListings.patchImagePathForDyld(imagePath)] ?? []
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

                self.loadState = runtimeListings.isImageLoaded(path: imagePath) ? .loaded : .notLoaded
            }


            runtimeListings.$classList
                .asObservable()
                .flatMap { [unowned self] _ in
                    try await runtimeListings.classNamesIn(image: imagePath)
                }
                .catchAndReturn([])
                .bind(to: $classNames)
                .disposed(by: rx.disposeBag)

            runtimeListings.$imageToProtocols
                .asObservable()
                .flatMap { [unowned self] imageToProtocols in
                    imageToProtocols[try await runtimeListings.patchImagePathForDyld(imagePath)] ?? []
                }
                .catchAndReturn([])
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
                    imageList.contains(try await runtimeListings.patchImagePathForDyld(imagePath))
                }
                .catchAndReturn(false)
                .filter { $0 } // only allow isLoaded to pass through; we don't want to erase an existing state
                .map { _ in
                    RuntimeImageLoadState.loaded
                }
                .asObservable()
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
                $0.compactMap { [weak self] runtimeObject -> SidebarImageCellViewModel? in
                    guard let self else { return nil }
                    return SidebarImageCellViewModel(runtimeObject: runtimeObject, appServices: appServices, router: router)
                }
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

        return Output(
            runtimeObjects: runtimeObjects,
            loadState: $loadState.asDriver(),
            notLoadedText: .just("\(imageName) is not yet loaded"),
            errorText: errorText,
            emptyText: .just("\(imageName) is loaded however does not appear to contain any classes or protocols"),
            isEmpty: .combineLatest($classNames.asDriver(), $protocolNames.asDriver(), resultSelector: { $0.isEmpty && $1.isEmpty }).startWith(classNames.isEmpty && protocolNames.isEmpty)
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

public class SidebarImageCellViewModel: ViewModel<SidebarRoute> {
    let runtimeObject: RuntimeObjectType

    @Observed
    public private(set) var icon: NSUIImage?

    @Observed
    public private(set) var name: NSAttributedString

    public init(runtimeObject: RuntimeObjectType, appServices: AppServices, router: any Router<SidebarRoute>) {
        self.runtimeObject = runtimeObject
        self.icon = runtimeObject.icon
        self.name = NSAttributedString {
            AText(runtimeObject.name)
                .font(.systemFont(ofSize: 13))
                .foregroundColor(.labelColor)
        }
        super.init(appServices: appServices, router: router)
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(runtimeObject)
        return hasher.finalize()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let object = object as? Self else { return false }
        return runtimeObject == object.runtimeObject
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension SidebarImageCellViewModel: Differentiable {}

#endif

extension RuntimeObjectType {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private static let iconSize: CGFloat = 16
    #endif

    #if canImport(UIKit)
    private static let iconSize: CGFloat = 24
    #endif

    public static let classIcon = IDEIcon("C", color: .yellow, style: .default, size: iconSize).image
    public static let protocolIcon = IDEIcon("Pr", color: .purple, style: .default, size: iconSize).image
//    public static let classIcon = SFSymbol(systemName: .cSquare).nsuiImage
//    public static let protocolIcon = SFSymbol(systemName: .pSquare).nsuiImage

    public var icon: NSUIImage {
        switch self {
        case .class: return Self.classIcon
        case .protocol: return Self.protocolIcon
        }
    }
}

extension RuntimeObjectType: Comparable {
    public static func < (lhs: RuntimeObjectType, rhs: RuntimeObjectType) -> Bool {
        switch (lhs, rhs) {
        case (.class, .protocol):
            return true
        case (.protocol, .class):
            return false
        case let (.class(className1), .class(className2)):
            return className1 < className2
        case let (.protocol(protocolName1), .protocol(protocolName2)):
            return protocolName1 < protocolName2
        }
    }
}

extension RuntimeImageLoadState: CaseAccessible {}

#if canImport(UIKit)

extension UIColor {
    static var labelColor: UIColor { .label }
}

#endif
