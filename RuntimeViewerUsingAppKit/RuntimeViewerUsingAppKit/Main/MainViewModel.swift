import AppKit
import UniformTypeIdentifiers
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerCommunication
import RuntimeViewerEngineManagement
import RuntimeViewerSettings
import RuntimeViewerUI

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

    static func == (leftState: Self, rightState: Self) -> Bool {
        leftState.title == rightState.title
            && leftState.isDisconnected == rightState.isDisconnected
            && leftState.selectedEngineIdentifier == rightState.selectedEngineIdentifier
            && leftState.image === rightState.image
    }
}

/// Whether Attach to Process can do anything for the engine currently selected, and when
/// it cannot, what to say about it.
///
/// A disabled control carrying its reason in a tooltip, rather than an enabled control
/// that reports the obstacle after being clicked: an action that cannot be performed is an
/// action whose control is off, and the user should not have to try it to find out. The
/// explanation is written to be read verbatim.
struct AttachAvailability: Equatable {
    let isEnabled: Bool
    let explanation: String

    static let probing = AttachAvailability(
        isEnabled: false,
        explanation: "Checking whether this device can attach to its own processes…",
    )

    /// Attaching needs SIP off, but only when the target is a process on *this* Mac. A
    /// device on the other end of the connection does its own injecting and could not care
    /// less about this machine's SIP state, which is why this is not a gate on the button
    /// as a whole.
    static let systemIntegrityProtectionEnabled = AttachAvailability(
        isEnabled: false,
        explanation: "Attaching to a process on this Mac needs System Integrity Protection disabled.",
    )

    /// An engine reached through another Mac. The hop exists and the commands would very
    /// likely be forwarded, but that has not been measured, so the entry says so instead
    /// of offering an action that may fail in a way nobody has seen yet.
    static let mirroredEngine = AttachAvailability(
        isEnabled: false,
        explanation: "Attaching to a process on an engine shared by another Mac is not supported yet.",
    )

    static let attachable = AttachAvailability(
        isEnabled: true,
        explanation: "Attach to a running process and inspect its runtime",
    )

    init(isEnabled: Bool, explanation: String) {
        self.isEnabled = isEnabled
        self.explanation = explanation
    }

    /// Maps what the far end said about itself.
    init(remoteAvailability: RuntimeInjectionAvailability) {
        switch remoteAvailability {
        case .available:
            self = .attachable
        case .requiresJailbrokenVariant:
            self.init(
                isEnabled: false,
                explanation: "This device is running the App Store build of Runtime Viewer, which cannot attach to other processes. The jailbroken build can.",
            )
        case .helperDaemonNotInstalled:
            self.init(
                isEnabled: false,
                explanation: "Attaching on that Mac needs its Runtime Viewer helper installed.",
            )
        case .unsupported(let reason):
            self.init(isEnabled: false, explanation: reason)
        }
    }
}

final class MainViewModel: ViewModel<MainRoute> {
    /// Bounds for the View menu's font-size commands, applied to `Settings.theme.fontSize`.
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
        let increaseFontSize: Signal<Void>
        let decreaseFontSize: Signal<Void>
        let resetFontSize: Signal<Void>
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
        let attachAvailability: Driver<AttachAvailability>
        let requestFrameworkSelection: Signal<Void>
        let requestSaveLocation: Signal<(name: String, type: UTType)>
        let requestRestartConfirmation: Signal<Void>
        let tabBarSnapshot: Driver<TabBarSnapshot>
        let isTabBarHidden: Driver<Bool>
    }

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    @Dependency(\.runtimeEngineIconProvider) private var runtimeEngineIconProvider

    @RxObserved private(set) var selectedEngineIdentifier: String = RuntimeEngine.local.engineID

    private var cachedSelectedEngineName: String = RuntimeEngine.local.source.description

    private var cachedSelectedEngineImage: NSImage?

    /// Fallback for attached processes that Launch Services knows nothing about.
    /// `NSRunningApplication(processIdentifier:)` only resolves registered GUI
    /// applications, so daemons (launchservicesd, rapportd, ...) never make it
    /// into `RuntimeEngineIconProvider`'s cache and would otherwise fall back to
    /// an App Store placeholder symbol. The generic executable icon is what the
    /// attach picker already shows for those processes.
    ///
    /// Resolved once: `NSWorkspace.icon(for:)` is expensive, and the source menu
    /// re-resolves an icon for every engine each time the engine list changes.
    private static let genericExecutableIcon = NSWorkspace.shared.icon(for: .unixExecutable)

    /// Whether this engine reached us through another Mac rather than being one this
    /// process connected to itself.
    ///
    /// Asked of the manager, not of the engine: how an engine arrived is a fact the
    /// manager keeps, and `RuntimeSource` cannot express it — a mirrored engine's
    /// `directTCP` source looks the same as a direct one's.
    private func isMirrored(_ runtimeEngine: RuntimeEngine) -> Bool {
        runtimeEngineManager.mirroredEngines.values.contains { $0 === runtimeEngine }
    }

    func resolveEngineIcon(for engine: RuntimeEngine) -> NSImage? {
        switch engine.source {
        case .local:
            return Self.machineIcon(for: engine)
        case .remote(_, let identifier, _) where identifier == .macCatalyst:
            return Self.machineIcon(for: engine)
        default:
            if engine.hostInfo.hostID == RuntimeNetworkBonjour.localInstanceID {
                return runtimeEngineIconProvider.cachedIcon(for: engine) ?? Self.genericExecutableIcon
            } else {
                // The machine itself, for the engine that *is* the machine — the
                // RuntimeViewer running on it. A process injected on that device
                // is a different thing and gets an icon of its own, recorded by
                // the attach flow; falling back to the device here would list
                // every injected process under a picture of the phone.
                return runtimeEngineIconProvider.cachedIcon(for: engine) ?? Self.machineIcon(for: engine)
            }
        }
    }

    /// The glyph standing for the machine an engine runs on.
    ///
    /// Every machine row goes through this, the local Mac included, because one
    /// photorealistic row beside three flat ones is worse than either treatment
    /// on its own. `deviceIcon(forModelIdentifier:)` stays as the last resort:
    /// it substitutes a generic display, which is a fair showing of a machine
    /// whose model and platform both said nothing.
    private static func machineIcon(for engine: RuntimeEngine) -> NSImage {
        let metadata = engine.hostInfo.metadata
        return DeviceGlyph.image(
            forModelIdentifier: metadata.modelIdentifier,
            operatingSystemVersion: metadata.osVersion,
            isSimulator: metadata.isSimulator,
        ) ?? NSWorkspace.shared.box.deviceIcon(forModelIdentifier: metadata.modelIdentifier)
    }

    private let requestRestartConfirmationRelay = PublishRelay<Void>()

    func transform(_ input: Input) -> Output {
        rx.disposeBag = DisposeBag()

        let requestFrameworkSelection = input.loadFrameworksClick.asSignal()

        // The picked framework is loaded by the document's engine, in whatever
        // process that engine runs in. It used to be `Bundle.load` — a dlopen
        // into this process — which is exactly what moving the local engine
        // into the XPC service exists to stop.
        input.frameworksSelected.emitOnNext { [weak self] urls in
            guard let self else { return }
            Task { @MainActor in
                for url in urls {
                    do {
                        guard let executableURL = Bundle(url: url)?.executableURL else {
                            throw MessageError.message("\(url.lastPathComponent) has no executable to load.")
                        }
                        try await self.documentState.runtimeEngine.loadImage(at: executableURL.path)
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

        input.increaseFontSize
            .throttle(.milliseconds(Self.fontSizeThrottleMilliseconds), latest: true)
            .emitOnNext {
                @Dependency(\.settings) var settings
                settings.theme.fontSize = min(Self.maximumFontSize, settings.theme.fontSize + 1)
            }
            .disposed(by: rx.disposeBag)

        input.decreaseFontSize
            .throttle(.milliseconds(Self.fontSizeThrottleMilliseconds), latest: true)
            .emitOnNext {
                @Dependency(\.settings) var settings
                settings.theme.fontSize = max(Self.minimumFontSize, settings.theme.fontSize - 1)
            }
            .disposed(by: rx.disposeBag)

        input.resetFontSize
            .emitOnNext {
                @Dependency(\.settings) var settings
                settings.theme.fontSize = Settings.Theme.default.fontSize
            }
            .disposed(by: rx.disposeBag)

        // No gate here any more: `attachAvailability` below drives the toolbar item's
        // enabled state, so a click can only arrive when the action is actually possible.
        // It used to run the SIP check and raise an alert on failure, which told the user
        // only after they had tried — and, once device engines existed, would have raised
        // it for a target that does not care about this Mac's SIP state at all.
        input.attachToProcessClick.emitOnNextMainActor { [weak self] in
            guard let self else { return }
            router.trigger(.attachToProcess)
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

        let selectedRuntimeObjectObservable: Observable<RuntimeObject?> =
            documentState.$selectedRuntimeObject.asObservable()

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
                        // Fetch through the interface cache with the same
                        // merged options as the content pane, so saving the
                        // visible object is a cache hit and the written text
                        // matches what the pane displays (the transformer
                        // configuration participates in both).
                        let semanticString = try await self.documentState.interfaceCache.interface(for: runtimeObject, options: self.currentMergedGenerationOptions)?.interfaceString
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
                            // Same cache + merged options as the save flow:
                            // sharing the visible object costs no engine
                            // round-trip and yields the displayed text.
                            let semanticString = try await documentState.interfaceCache.interface(for: runtimeObjectType, options: self.currentMergedGenerationOptions)?.interfaceString
                            completion(semanticString?.string.data(using: .utf8), nil)
                        } catch {
                            completion(nil, error)
                        }
                    }
                    return nil
                }

                return [SharingData(provider: item, title: runtimeObjectType.displayName, iconType: runtimeObjectType.kind)]
            }

        // Attach to Process now means "pick a process on the machine the selected engine
        // belongs to", so what it can do changes with that engine. The host branch stays
        // synchronous: it is the common case, it already has a working answer, and a
        // control that flickers from enabled to disabled while a probe runs is worse than
        // one that was never enabled.
        let attachAvailability: Driver<AttachAvailability> = documentState.$runtimeEngine.asDriver()
            .flatMapLatest { [weak self] runtimeEngine -> Driver<AttachAvailability> in
                guard let self else { return .empty() }
                if runtimeEngine.injectionTargetsRunOnThisMachine {
                    return .just(SIPChecker.isDisabled() ? .attachable : .systemIntegrityProtectionEnabled)
                }
                if isMirrored(runtimeEngine) {
                    // Deliberately not probed: the forwarding path has never been
                    // exercised, and asking would offer an action on the strength of a
                    // guess about it.
                    return .just(.mirroredEngine)
                }
                return Observable.async { await runtimeEngine.injectionAvailability() }
                    .map(AttachAvailability.init(remoteAvailability:))
                    .asDriver(onErrorJustReturn: .init(remoteAvailability: .unsupported(
                        reason: "Could not ask this device whether it can attach to its own processes.",
                    )))
                    .startWith(.probing)
            }
            .distinctUntilChanged()

        // The manager's sections, re-emitted when an icon lands after them.
        //
        // An injected device process's icon does: the attach flow can only file
        // it once that process's engine has reported in, by which time the list
        // has been published and drawn. Both consumers below resolve icons, so
        // both need the nudge — the menu rows and the toolbar button's own image.
        let runtimeEngineSections = Driver.combineLatest(
            runtimeEngineManager.rx.runtimeEngineSections,
            runtimeEngineIconProvider.recordedIconsChanged.startWith(()),
        ) { sections, _ in sections }

        let switchSourceState = Driver.combineLatest(
            runtimeEngineSections,
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
                items: tabs.map { TabBarItem(id: $0.id, title: $0.title, kind: $0.object?.kind) },
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
            isSavable: documentState.$selectedRuntimeObject.asDriver().map { $0 != nil },
            isSidebarBackHidden: documentState.$currentImageNode.asDriver().map { $0 == nil },
            isNavigationHidden: documentState.$selectionStack.asDriver().map { $0.isEmpty },
            // On an empty tab (`selectedRuntimeObject == nil` over a
            // non-empty timeline) the first `.backward` returns to the
            // cursor entry itself, so previous stays enabled from index 0.
            canGoPrevious: Driver.combineLatest(
                documentState.$selectionIndex.asDriver(),
                documentState.$selectedRuntimeObject.asDriver()
            ).map { index, selected in
                selected == nil ? index >= 0 : index > 0
            },
            canGoNext: Driver.combineLatest(
                documentState.$selectionStack.asDriver(),
                documentState.$selectionIndex.asDriver()
            ).map { stack, index in
                index < stack.count - 1
            },
            navigationHistory: Driver.combineLatest(
                documentState.$selectionStack.asDriver(),
                documentState.$selectionIndex.asDriver(),
                documentState.$selectedRuntimeObject.asDriver()
            ).map { stack, index, selected in
                NavigationHistorySnapshot(
                    items: stack.enumerated().map { entryIndex, runtimeObject in
                        NavigationHistoryItem(
                            index: entryIndex,
                            displayName: runtimeObject.displayName,
                            icon: RuntimeObjectIcon.icon(for: runtimeObject.kind, size: NavigationHistorySnapshot.iconSize)
                        )
                    },
                    // An empty tab hovers just above the cursor: the cursor
                    // entry itself becomes the nearest backward row.
                    currentIndex: selected == nil && index >= 0 ? index + 1 : index
                )
            },
            runtimeEngineSections: runtimeEngineSections,
            switchSourceState: switchSourceState,
            attachAvailability: attachAvailability,
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
