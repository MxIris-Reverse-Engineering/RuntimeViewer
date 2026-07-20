import AppKit
import UniformTypeIdentifiers
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCommunication
import RuntimeViewerSettings

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
    /// Bounds for the toolbar font-size controls, applied to `Settings.theme.fontSize`.
    private static let minimumFontSize: Double = 8
    private static let maximumFontSize: Double = 32

    private static let fontSizeThrottleMilliseconds: Int = 120

    struct Input {
        let sidebarBackClick: Signal<Void>
        let navigationPreviousClick: Signal<Void>
        let navigationNextClick: Signal<Void>
        /// Target index into `selectionStack`, chosen from a long-press
        /// history menu on either navigation segment.
        let navigationHistorySelected: Signal<Int>
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
        let tabSelected: Signal<Int>
        let tabClosed: Signal<Int>
        let newTabClicked: Signal<Void>
    }

    struct Output {
        /// Everything the `TitleToolbarItem` (and the window title) shows is
        /// derived here from `DocumentState` rather than pushed in by whichever
        /// pane happens to become visible — the panes have no business owning
        /// window-level chrome, and the push model used to leave the subtitle
        /// stale whenever a reused controller rebound.
        let windowTitle: Driver<String>
        let toolbarTitle: Driver<String>
        let toolbarSubtitle: Driver<String>
        let sharingServiceData: Observable<[SharingData]>
        let isSavable: Driver<Bool>
        let isSidebarBackHidden: Driver<Bool>
        let isNavigationHidden: Driver<Bool>
        let canGoPrevious: Driver<Bool>
        let canGoNext: Driver<Bool>
        let navigationHistory: Driver<NavigationHistorySnapshot>
        let runtimeEngineSections: Driver<[RuntimeEngineSection]>
        let switchSourceState: Driver<SwitchSourceState>
        let requestFrameworkSelection: Signal<Void>
        let requestSaveLocation: Signal<(name: String, type: UTType)>
        let requestRestartConfirmation: Signal<Void>
        let tabBarSnapshot: Driver<TabBarSnapshot>
        let isTabBarHidden: Driver<Bool>
    }

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

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

        input.fontSizeSmallerClick
            .throttle(.milliseconds(Self.fontSizeThrottleMilliseconds), latest: true)
            .emitOnNext {
                @Dependency(\.settings) var settings
                settings.theme.fontSize = max(Self.minimumFontSize, settings.theme.fontSize - 1)
            }
            .disposed(by: rx.disposeBag)

        input.fontSizeLargerClick
            .throttle(.milliseconds(Self.fontSizeThrottleMilliseconds), latest: true)
            .emitOnNext {
                @Dependency(\.settings) var settings
                settings.theme.fontSize = min(Self.maximumFontSize, settings.theme.fontSize + 1)
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

        input.sidebarBackClick.emitOnNext { [weak self] in
            guard let self else { return }
            documentState.selectionRouter.trigger(.switchImage(nil))
        }
        .disposed(by: rx.disposeBag)

        input.navigationPreviousClick.emitOnNext { [weak self] in
            guard let self else { return }
            documentState.selectionRouter.trigger(.backward)
        }
        .disposed(by: rx.disposeBag)

        input.navigationNextClick.emitOnNext { [weak self] in
            guard let self else { return }
            documentState.selectionRouter.trigger(.forward)
        }
        .disposed(by: rx.disposeBag)

        input.navigationHistorySelected.emitOnNext { [weak self] targetIndex in
            guard let self else { return }
            documentState.selectionRouter.trigger(.jump(toIndex: targetIndex))
        }
        .disposed(by: rx.disposeBag)

        input.generationOptionsClick.emit(with: self) { $0.router.trigger(.generationOptions(sender: $1)) }.disposed(by: rx.disposeBag)

        input.mcpStatusClick.emit(with: self) { $0.router.trigger(.mcpStatus(sender: $1)) }.disposed(by: rx.disposeBag)

        input.backgroundIndexingClick.emit(with: self) { $0.router.trigger(.backgroundIndexing(sender: $1)) }.disposed(by: rx.disposeBag)

        let selectedRuntimeObjectObservable: Observable<RuntimeObject?> = Observable.combineLatest(
            documentState.$selectionStack.asObservable(),
            documentState.$selectionIndex.asObservable()
        ).map { stack, index in
            guard index >= 0, index < stack.count else { return nil }
            return stack[index]
        }

        let selectedRuntimeObjectSignal = selectedRuntimeObjectObservable
            .asSignal(onErrorSignalWith: .empty())

        let requestSaveLocation = input.saveClick
            .withLatestFrom(selectedRuntimeObjectSignal)
            .filterNil()
            .map { (name: $0.displayName, type: $0.contentType) }

        input.saveLocationSelected
            .withLatestFrom(selectedRuntimeObjectSignal) { saveLocation, selectedRuntimeObject in
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

        let sharingServiceData = selectedRuntimeObjectObservable
            .map { [weak self] selected -> [SharingData] in
                guard let self, let runtimeObjectType = selected else { return [] }

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

        let currentImageName = documentState.$currentImageNode.asDriver().map { $0?.name }

        // MARK: - Tabs

        input.tabSelected.emitOnNext { [weak self] index in
            guard let self else { return }
            documentState.selectionRouter.trigger(.switchTab(index: index))
        }
        .disposed(by: rx.disposeBag)

        input.tabClosed.emitOnNext { [weak self] index in
            guard let self else { return }
            documentState.selectionRouter.trigger(.closeTab(index: index))
        }
        .disposed(by: rx.disposeBag)

        input.newTabClicked.emitOnNext { [weak self] in
            guard let self else { return }
            documentState.selectionRouter.trigger(.newTab)
        }
        .disposed(by: rx.disposeBag)

        let tabBarSnapshot = Driver.combineLatest(
            documentState.$tabs.asDriver(),
            documentState.$activeTabIndex.asDriver()
        ) { tabs, activeIndex in
            TabBarSnapshot(
                items: tabs.map { TabBarItem(title: $0.title, kind: $0.object?.kind) },
                activeIndex: activeIndex
            )
        }

        return Output(
            // combineLatest rather than reading `runtimeEngine` inside the
            // image-node subscription: an engine switch has to retitle the
            // window even though it clears `currentImageNode` to the same
            // `nil` it may already hold.
            windowTitle: Driver.combineLatest(
                documentState.$runtimeEngine.asDriver(),
                currentImageName
            ).map { runtimeEngine, imageName in
                guard let imageName else { return runtimeEngine.source.description }
                return "\(runtimeEngine.source.description) - \(imageName)"
            },
            toolbarTitle: currentImageName.map { $0 ?? "RuntimeViewer" },
            toolbarSubtitle: selectedRuntimeObjectObservable
                .map { $0?.displayName ?? "" }
                .asDriver(onErrorJustReturn: ""),
            sharingServiceData: sharingServiceData,
            isSavable: documentState.$selectionStack.asDriver().map { !$0.isEmpty },
            isSidebarBackHidden: documentState.$currentImageNode.asDriver().map { $0 == nil },
            isNavigationHidden: documentState.$selectionStack.asDriver().map { $0.isEmpty },
            canGoPrevious: documentState.$selectionIndex.asDriver().map { $0 > 0 },
            canGoNext: Driver.combineLatest(
                documentState.$selectionStack.asDriver(),
                documentState.$selectionIndex.asDriver()
            ).map { stack, index in
                index < stack.count - 1
            },
            navigationHistory: Driver.combineLatest(
                documentState.$selectionStack.asDriver(),
                documentState.$selectionIndex.asDriver()
            ).map { stack, index in
                NavigationHistorySnapshot(
                    items: stack.enumerated().map { entryIndex, runtimeObject in
                        NavigationHistoryItem(
                            index: entryIndex,
                            displayName: runtimeObject.displayName,
                            icon: RuntimeObjectIcon.icon(for: runtimeObject.kind, size: NavigationHistorySnapshot.iconSize)
                        )
                    },
                    currentIndex: index
                )
            },
            runtimeEngineSections: runtimeEngineManager.rx.runtimeEngineSections,
            switchSourceState: switchSourceState,
            requestFrameworkSelection: requestFrameworkSelection,
            requestSaveLocation: requestSaveLocation,
            requestRestartConfirmation: requestRestartConfirmationRelay.asSignal(),
            tabBarSnapshot: tabBarSnapshot,
            isTabBarHidden: tabBarSnapshot.map { $0.items.count <= 1 }.distinctUntilChanged()
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
