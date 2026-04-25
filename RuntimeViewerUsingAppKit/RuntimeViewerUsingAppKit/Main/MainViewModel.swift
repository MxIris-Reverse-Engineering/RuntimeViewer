import AppKit
import UniformTypeIdentifiers
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCommunication

enum MessageError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

struct SharingData {
    let provider: NSItemProvider
    let title: String
    let iconType: RuntimeObjectKind
}

struct SwitchSourceState: Equatable {
    let title: String
    let image: NSImage?
    let isDisconnected: Bool
    let selectedEngineIdentifier: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title
            && lhs.isDisconnected == rhs.isDisconnected
            && lhs.selectedEngineIdentifier == rhs.selectedEngineIdentifier
            && lhs.image === rhs.image
    }
}

final class MainViewModel: ViewModel<MainRoute> {
    struct Input {
        let sidebarBackClick: Signal<Void>
        let contentBackClick: Signal<Void>
        let saveClick: Signal<Void>
        let switchSource: Signal<String?>
        let generationOptionsClick: Signal<NSView>
        let fontSizeSmallerClick: Signal<Void>
        let fontSizeLargerClick: Signal<Void>
        let loadFrameworksClick: Signal<Void>
//        let installHelperClick: Signal<Void>
        let attachToProcessClick: Signal<Void>
        let mcpStatusClick: Signal<NSView>
        let backgroundIndexingClick: Signal<NSView>
        let frameworksSelected: Signal<[URL]>
        let saveLocationSelected: Signal<URL>
    }

    struct Output {
        let sharingServiceData: Observable<[SharingData]>
        let isSavable: Driver<Bool>
        let isSidebarBackHidden: Driver<Bool>
        let isContentBackHidden: Driver<Bool>
        let runtimeEngineSections: Driver<[RuntimeEngineSection]>
        let switchSourceState: Driver<SwitchSourceState>
        let requestFrameworkSelection: Signal<Void>
        let requestSaveLocation: Signal<(name: String, type: UTType)>
        let requestRestartConfirmation: Signal<Void>
    }

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    var completeTransition: Observable<SidebarRoute>? {
        didSet {
            completeTransitionDisposable?.dispose()
            completeTransitionDisposable = completeTransition?.map { if case .selectedObject(let runtimeObject) = $0 { runtimeObject } else { nil } }.bind(to: $selectedRuntimeObject)
        }
    }

    var completeTransitionDisposable: Disposable?

    let isContentStackDepthGreaterThanOne = BehaviorRelay<Bool>(value: false)

    @Observed private(set) var selectedEngineIdentifier: String = RuntimeEngine.local.engineID

    private var cachedSelectedEngineName: String = RuntimeEngine.local.source.description

    private var cachedSelectedEngineImage: NSImage?

    func resolveEngineIcon(for engine: RuntimeEngine) -> NSImage? {
        switch engine.source {
        case .local:
            return NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
        case .remote(_, let identifier, _) where identifier == .macCatalyst:
            return NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
        default:
            if engine.hostInfo.hostID == RuntimeNetworkBonjour.localInstanceID {
                return runtimeEngineManager.cachedIcon(for: engine) ?? .symbol(name: RuntimeViewerSymbols.appFill)
            } else {
                let fallback = engine.hostInfo.metadata.isSimulator
                    ? NSWorkspace.shared.box.deviceSymbolIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
                    : NSWorkspace.shared.box.deviceIcon(forModelIdentifier: engine.hostInfo.metadata.modelIdentifier)
                return runtimeEngineManager.cachedIcon(for: engine) ?? fallback
            }
        }
    }

    @Observed
    var selectedRuntimeObject: RuntimeObject?

    private let requestRestartConfirmationRelay = PublishRelay<Void>()

    func transform(_ input: Input) -> Output {
        rx.disposeBag = DisposeBag()

        let requestFrameworkSelection = input.loadFrameworksClick.asSignal()

        input.frameworksSelected.emitOnNext { [weak self] urls in
            guard let self else { return }
            Task { @MainActor in
                for url in urls {
                    do {
                        try Bundle(url: url)?.loadAndReturnError()
                        await self.documentState.runtimeEngine.reloadData(isReloadImageNodes: false)
                    } catch {
                        self.errorRelay.accept(error)
                    }
                }
            }
        }.disposed(by: rx.disposeBag)

        

//        input.installHelperClick.emitOnNext { [weak self] in
//            guard let self else { return }
//            Task { @MainActor in
//                do {
//                    try RuntimeHelperClient.installLegacyHelper()
//                    self.requestRestartConfirmationRelay.accept(())
//                } catch {
//                    self.errorRelay.accept(error)
//                }
//            }
//        }
//        .disposed(by: rx.disposeBag)

        input.fontSizeSmallerClick.emitOnNext { [weak self] in
            guard let self else { return }
            appDefaults.themeProfile.fontSizeSmaller()
        }
        .disposed(by: rx.disposeBag)

        input.fontSizeLargerClick.emitOnNext { [weak self] in
            guard let self else { return }
            appDefaults.themeProfile.fontSizeLarger()
        }
        .disposed(by: rx.disposeBag)

        input.attachToProcessClick.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            if SIPChecker.isDisabled() {
                router.trigger(.attachToProcess)
            } else {
                errorRelay.accept(MessageError.message("SIP is enabled. Please disable SIP to attach to process."))
            }
        }
        .disposed(by: rx.disposeBag)

        input.sidebarBackClick.emit(to: router.rx.trigger(.sidebarBack)).disposed(by: rx.disposeBag)

        input.contentBackClick.emit(to: router.rx.trigger(.contentBack)).disposed(by: rx.disposeBag)

        input.generationOptionsClick.emit(with: self) { $0.router.trigger(.generationOptions(sender: $1)) }.disposed(by: rx.disposeBag)

        input.mcpStatusClick.emit(with: self) { $0.router.trigger(.mcpStatus(sender: $1)) }.disposed(by: rx.disposeBag)

        input.backgroundIndexingClick.emit(with: self) { $0.router.trigger(.backgroundIndexing(sender: $1)) }.disposed(by: rx.disposeBag)

        let requestSaveLocation = input.saveClick
            .withLatestFrom($selectedRuntimeObject.asSignalOnErrorJustComplete())
            .filterNil()
            .map { (name: $0.displayName, type: $0.contentType) }

        input.saveLocationSelected
            .withLatestFrom($selectedRuntimeObject.asSignalOnErrorJustComplete()) { saveLocation, selectedRuntimeObject in
                selectedRuntimeObject.map { (saveLocation, $0) }
            }
            .filterNil()
            .emitOnNext { [weak self] url, runtimeObject in
                guard let self else { return }
                Task {
                    do {
                        let semanticString = try await self.documentState.runtimeEngine.interface(for: runtimeObject, options: self.appDefaults.options)?.interfaceString
                        try semanticString?.string.write(to: url, atomically: true, encoding: .utf8)
                    } catch {
                        self.errorRelay.accept(error)
                    }
                }
            }.disposed(by: rx.disposeBag)

        input.switchSource.compactMap { $0 }.emit(with: self) { owner, identifier in
            guard let engine = owner.runtimeEngineManager.runtimeEngines.first(where: {
                $0.engineID == identifier
            }) else { return }
            owner.cachedSelectedEngineName = engine.source.description
            owner.cachedSelectedEngineImage = owner.resolveEngineIcon(for: engine)
            owner.router.trigger(.main(engine))
            owner.selectedEngineIdentifier = identifier
        }.disposed(by: rx.disposeBag)

        let sharingServiceData = completeTransition?.map { [weak self] router -> [SharingData] in
            guard let self, case .selectedObject(let runtimeObjectType) = router else { return [] }
            
            let item = NSItemProvider()
            
            item.registerDataRepresentation(forTypeIdentifier: runtimeObjectType.contentType.identifier, visibility: .all) { [weak self] completion in
                guard let self else {
                    completion(nil, nil)
                    return nil
                }
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let semanticString = try await documentState.runtimeEngine.interface(for: runtimeObjectType, options: self.appDefaults.options)?.interfaceString
                        completion(semanticString?.string.data(using: .utf8), nil)
                    } catch {
                        completion(nil, error)
                    }
                }
                return nil
            }
            
            return [SharingData(provider: item, title: runtimeObjectType.displayName, iconType: runtimeObjectType.kind)]
        }

        let switchSourceState = Driver.combineLatest(
            runtimeEngineManager.rx.runtimeEngineSections,
            $selectedEngineIdentifier.asDriver()
        ).map { [weak self] sections, selectedIdentifier -> SwitchSourceState in
            guard let self else {
                return SwitchSourceState(title: "RuntimeViewer", image: nil, isDisconnected: true, selectedEngineIdentifier: selectedIdentifier)
            }
            let allEngines = sections.flatMap(\.engines)
            if let engine = allEngines.first(where: { $0.engineID == selectedIdentifier }) {
                let name = engine.source.description
                let image = resolveEngineIcon(for: engine)
                cachedSelectedEngineName = name
                cachedSelectedEngineImage = image
                return SwitchSourceState(
                    title: name,
                    image: image,
                    isDisconnected: false,
                    selectedEngineIdentifier: selectedIdentifier
                )
            } else {
                return SwitchSourceState(
                    title: cachedSelectedEngineName + " (Disconnected)",
                    image: cachedSelectedEngineImage,
                    isDisconnected: true,
                    selectedEngineIdentifier: selectedIdentifier
                )
            }
        }

        return Output(
            sharingServiceData: sharingServiceData ?? .empty(),
            isSavable: $selectedRuntimeObject.asDriver().map { $0 != nil },
            isSidebarBackHidden: completeTransition?.map {
                if $0.isClickedNode || $0.isSelectedObject {
                    false
                } else {
                    true
                }
            }.asDriver(onErrorJustReturn: true) ?? .just(true),
            isContentBackHidden: isContentStackDepthGreaterThanOne.map {
                !$0
            }.asDriver(onErrorJustReturn: true),
            runtimeEngineSections: runtimeEngineManager.rx.runtimeEngineSections,
            switchSourceState: switchSourceState,
            requestFrameworkSelection: requestFrameworkSelection,
            requestSaveLocation: requestSaveLocation,
            requestRestartConfirmation: requestRestartConfirmationRelay.asSignal()
        )
    }
}

extension UTType {
    fileprivate static let swiftInterface: Self = .init(filenameExtension: "swiftinterface") ?? .swiftSource
}

extension RuntimeObject {
    fileprivate var contentType: UTType {
        switch kind {
        case .c,
             .objc:
            return .cHeader
        case .swift:
            return .swiftInterface
        }
    }
}
