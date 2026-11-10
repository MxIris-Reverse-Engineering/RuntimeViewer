import AppKit
import UniformTypeIdentifiers
import RuntimeViewerCore
import RuntimeViewerInjection
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
    /// The source's icon in a list: a machine's glyph squared.
    let image: NSImage?
    /// The source's icon in the toolbar's runtime source picker: a machine's glyph as the symbol it
    /// is, which Xcode 27's style draws at its own size.
    let pickerIcon: RuntimeSourcePicker.Icon?
    let isDisconnected: Bool
    let selectedEngineIdentifier: String

    static func == (leftState: Self, rightState: Self) -> Bool {
        leftState.title == rightState.title
            && leftState.isDisconnected == rightState.isDisconnected
            && leftState.selectedEngineIdentifier == rightState.selectedEngineIdentifier
            && leftState.image === rightState.image
            && leftState.pickerIcon == rightState.pickerIcon
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
        /// Target index into the focused tab's history, chosen from a
        /// long-press history menu on either navigation segment.
        let navigationHistorySelected: Signal<Int>
        let saveClick: Signal<Void>
        /// The engine identifier of a source chosen in the runtime source picker's list.
        let switchSource: Signal<String>
        let generationOptionsClick: Signal<Void>
        let increaseFontSize: Signal<Void>
        let decreaseFontSize: Signal<Void>
        let resetFontSize: Signal<Void>
        let loadFrameworksClick: Signal<Void>
//        let installHelperClick: Signal<Void>
        let attachToProcessClick: Signal<Void>
        let mcpStatusClick: Signal<Void>
        /// A click on the toolbar's activity display: the Report navigator lists the work in detail.
        let activityClick: Signal<Void>
        let frameworksSelected: Signal<[URL]>
        let saveLocationSelected: Signal<URL>
        /// A choice from the runtime source picker's Dependency Cache level, for
        /// the offline engine the window is on: `nil` reads the file alone.
        let dependencyCacheSelected: Signal<RuntimeOfflineFile.DependencyCache?>
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
        /// What the runtime source pickers show: the source the window is on.
        let switchSourceState: Driver<SwitchSourceState>
        /// What the runtime source picker lists when it opens.
        let runtimeSourcePickerContent: Driver<RuntimeSourcePickerContent>
        let attachAvailability: Driver<AttachAvailability>
        /// Load Frameworks… loads an image into the engine's process, which an
        /// offline engine does not have.
        let isLoadFrameworksEnabled: Driver<Bool>
        let requestFrameworkSelection: Signal<Void>
        let requestSaveLocation: Signal<(name: String, type: UTType)>
        let requestRestartConfirmation: Signal<Void>
        /// Where the toolbar shows the activity: the user's setting as it stands on this system,
        /// never `.automatic`.
        let activityStyle: Driver<Settings.ToolbarActivityStyle>
        /// What the toolbar's activity display shows, in the capsule or in the window title's
        /// progress ring as `activityStyle` says.
        let activity: Driver<ToolbarActivityState>
        /// The title's icon in Xcode 27's style, which the progress ring takes the place of.
        let toolbarIcon: Driver<NSImage?>
    }

    /// The title's icon: the kind of the image the title names, as one glyph in one colour, as
    /// Xcode 27 draws its project icon — brown for a bundle, after Xcode's package icon, blue
    /// otherwise — and while no image is open the app's own symbol, in blue too, rather than a
    /// picture of the app icon among the glyphs.
    private static func toolbarIcon(for imageNode: RuntimeImageNode?) -> NSImage? {
        guard let imageNode else {
            return TitleDocumentIcon.image(symbol: SFSymbols(name: RuntimeViewerSymbols.runtimeViewer).nsImage, color: .systemBlue)
        }
        let symbol = imageNode.icon
        let color: NSColor = symbol === RuntimeImageNode.bundleIcon ? .systemBrown : .systemBlue
        return TitleDocumentIcon.image(symbol: symbol, color: color)
    }

    private lazy var toolbarActivityPresenter = ToolbarActivityPresenter(documentState: documentState)

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    @Dependency(\.runtimeEngineIconProvider) private var runtimeEngineIconProvider

    @Dependency(\.offlineFileController) private var offlineFileController

    @RxObserved private(set) var selectedEngineIdentifier: String = RuntimeEngine.local.engineID

    private var cachedSelectedEngineName: String = RuntimeEngine.local.source.description

    private var cachedSelectedEngineImage: NSImage?

    private var cachedSelectedEnginePickerIcon: RuntimeSourcePicker.Icon?

    /// Whether this engine reached us through another Mac rather than being one this
    /// process connected to itself.
    ///
    /// Asked of the manager, not of the engine: how an engine arrived is a fact the
    /// manager keeps, and `RuntimeSource` cannot express it — a mirrored engine's
    /// `directTCP` source looks the same as a direct one's.
    private func isMirrored(_ runtimeEngine: RuntimeEngine) -> Bool {
        runtimeEngineManager.mirroredEngines.values.contains { $0 === runtimeEngine }
    }

    /// Moves the window to `engine`, which is ready.
    private func switchToEngine(_ engine: RuntimeEngine) {
        cachedSelectedEngineName = engine.source.description
        cachedSelectedEngineImage = runtimeEngineIconProvider.icon(for: engine)
        cachedSelectedEnginePickerIcon = runtimeEngineIconProvider.sourcePickerIcon(for: engine)
        router.trigger(.main(engine))
        selectedEngineIdentifier = engine.engineID
    }

    private let requestRestartConfirmationRelay = PublishRelay<Void>()

    func transform(_ input: Input) -> Output {
        rx.disposeBag = DisposeBag()

        // The engine the document opened on, which is not "My Mac" for a file
        // opened offline.
        selectedEngineIdentifier = documentState.runtimeEngine.engineID
        cachedSelectedEngineName = documentState.runtimeEngine.source.description

        let requestFrameworkSelection = input.loadFrameworksClick.asSignal()

        // The picked framework is loaded by the document's engine, in whatever
        // process that engine runs in. It used to be `Bundle.load` — a dlopen
        // into this process — which is exactly what moving the local engine
        // into the XPC service exists to stop. A framework of the shared cache
        // an attached process borrows still goes into that process: loading it
        // there is what was asked for, and its data still comes from its owner.
        input.frameworksSelected.emitOnNext { [weak self] urls in
            guard let self else { return }
            Task { @MainActor in
                for url in urls {
                    do {
                        guard let executableURL = Bundle(url: url)?.executableURL else {
                            throw MessageError.message("\(url.lastPathComponent) has no executable to load.")
                        }
                        try await self.documentState.runtimeEngine.loadImageInServingProcess(at: executableURL.path)
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

        input.generationOptionsClick.emit(with: self) { owner, _ in owner.router.trigger(.generationOptions) }.disposed(by: rx.disposeBag)

        input.mcpStatusClick.emit(with: self) { owner, _ in owner.router.trigger(.mcpStatus) }.disposed(by: rx.disposeBag)

        input.activityClick.emit(with: self) { owner, _ in owner.router.trigger(.reports) }.disposed(by: rx.disposeBag)

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

        input.switchSource.emit(with: self) { owner, identifier in
            guard let engine = owner.runtimeEngineManager.runtimeEngines.first(where: {
                $0.engineID == identifier
            }) else { return }
            guard owner.runtimeEngineManager.isOfflineEngineSuspended(engine),
                  let file = owner.runtimeEngineManager.offlineFile(of: engine)
            else {
                owner.switchToEngine(engine)
                return
            }
            // Its process was let go while no window was on it: the window
            // moves there at once, saying it is reading, while a new instance
            // reads the file again.
            Task { @MainActor [weak owner] in
                guard let owner else { return }
                do {
                    let engine = try await owner.runtimeEngineManager.startReading(file)
                    owner.switchToEngine(engine)
                    try await owner.runtimeEngineManager.waitUntilFileIsRead(by: engine)
                } catch {
                    owner.errorRelay.accept(error)
                }
            }
        }.disposed(by: rx.disposeBag)

        input.dependencyCacheSelected.emitOnNext { [weak self] dependencyCache in
            guard let self else { return }
            let engine = documentState.runtimeEngine
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await offlineFileController.pair(engine, with: dependencyCache)
                } catch {
                    errorRelay.accept(error)
                }
            }
        }.disposed(by: rx.disposeBag)

        let runtimeEngineOfDocument = documentState.$runtimeEngineSession.asDriver().map(\.engine)
        let isLoadFrameworksEnabled = runtimeEngineOfDocument.map { engine -> Bool in
            if case .file = engine.source { return false }
            return true
        }

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
        let attachAvailability: Driver<AttachAvailability> = documentState.$runtimeEngineSession.asDriver().map(\.engine)
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
                return SwitchSourceState(title: "RuntimeViewer", image: nil, pickerIcon: nil, isDisconnected: true, selectedEngineIdentifier: selectedIdentifier)
            }
            let allEngines = sections.flatMap(\.engines)
            if let engine = allEngines.first(where: { $0.engineID == selectedIdentifier }) {
                let name = engine.source.description
                let image = runtimeEngineIconProvider.icon(for: engine)
                let pickerIcon = runtimeEngineIconProvider.sourcePickerIcon(for: engine)
                cachedSelectedEngineName = name
                cachedSelectedEngineImage = image
                cachedSelectedEnginePickerIcon = pickerIcon
                return SwitchSourceState(
                    title: name,
                    image: image,
                    pickerIcon: pickerIcon,
                    isDisconnected: false,
                    selectedEngineIdentifier: selectedIdentifier
                )
            } else {
                return SwitchSourceState(
                    title: cachedSelectedEngineName + " (Disconnected)",
                    image: cachedSelectedEngineImage,
                    pickerIcon: cachedSelectedEnginePickerIcon,
                    isDisconnected: true,
                    selectedEngineIdentifier: selectedIdentifier
                )
            }
        }

        // What the runtime source picker lists: the manager's sections with the window's source
        // checked, that source on top while its engine is gone, and the dependency caches the
        // window's offline file can be paired with.
        let runtimeSourcePickerContent = Driver.combineLatest(
            runtimeEngineSections,
            switchSourceState,
            runtimeEngineOfDocument
        ) { [weak self] sections, state, engineOfDocument -> RuntimeSourcePickerContent in
            guard let self else { return .empty }
            let disconnectedSource = state.isDisconnected ? RuntimeSourcePickerContent.Source(
                engineIdentifier: state.selectedEngineIdentifier,
                title: state.title,
                image: state.image,
                isCurrent: true,
                isEnabled: false
            ) : nil
            return RuntimeSourcePickerContent(
                disconnectedSource: disconnectedSource,
                sections: sections.map { section in
                    RuntimeSourcePickerContent.Section(
                        title: section.hostName,
                        sources: section.engines.map { engine in
                            RuntimeSourcePickerContent.Source(
                                engineIdentifier: engine.engineID,
                                title: engine.source.description,
                                image: self.runtimeEngineIconProvider.icon(for: engine),
                                isCurrent: engine.engineID == state.selectedEngineIdentifier
                            )
                        }
                    )
                },
                dependencyCacheChoices: offlineFileController.dependencyCacheChoices(for: engineOfDocument).map { choice in
                    RuntimeSourcePickerContent.DependencyCacheChoice(
                        title: choice.title,
                        dependencyCache: choice.dependencyCache,
                        isCurrent: choice.isCurrent
                    )
                }
            )
        }

        let currentImageName = documentState.$currentImageNode.asDriver().map { $0?.name }

        // MARK: - Navigation

        // Each editor pane's tab bar is its own (`EditorPaneViewModel`); the
        // toolbar's back and forward walk the focused pane's active tab.
        let focusedTabHistory = documentState.$editorArea.asDriver()
            .map { $0.focusedPane.activeTab.history }

        // Resolved once: `Observable.tracking` re-arms on a main-queue hop, where the dependency
        // context is gone.
        let trackedSettings = settings
        let activityStyle = Observable<Settings.ToolbarActivityStyle>
            .tracking {
                MainActor.assumeIsolated {
                    trackedSettings.general.toolbarActivityStyle.resolved
                }
            }
            .distinctUntilChanged()
            .asDriver(onErrorDriveWith: .empty())

        return Output(
            // combineLatest rather than reading `runtimeEngine` inside the
            // image-node subscription: an engine switch has to retitle the
            // window even though it clears `currentImageNode` to the same
            // `nil` it may already hold.
            windowTitle: Driver.combineLatest(
                documentState.$runtimeEngineSession.asDriver().map(\.engine),
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
            // The focused pane's active tab: every tab walks only what it has
            // shown, so switching tabs or panes switches what back and forward
            // reach.
            isNavigationHidden: focusedTabHistory.map { $0.entries.isEmpty }.distinctUntilChanged(),
            canGoPrevious: focusedTabHistory.map(\.canGoBackward).distinctUntilChanged(),
            canGoNext: focusedTabHistory.map(\.canGoForward).distinctUntilChanged(),
            navigationHistory: focusedTabHistory.map { history in
                NavigationHistorySnapshot(
                    items: history.entries.enumerated().map { entryIndex, runtimeObject in
                        NavigationHistoryItem(
                            index: entryIndex,
                            displayName: runtimeObject.displayName,
                            icon: RuntimeObjectIcon.icon(for: runtimeObject.kind, size: NavigationHistorySnapshot.iconSize)
                        )
                    },
                    currentIndex: history.currentIndex ?? -1
                )
            },
            switchSourceState: switchSourceState,
            runtimeSourcePickerContent: runtimeSourcePickerContent,
            attachAvailability: attachAvailability,
            isLoadFrameworksEnabled: isLoadFrameworksEnabled,
            requestFrameworkSelection: requestFrameworkSelection,
            requestSaveLocation: requestSaveLocation,
            requestRestartConfirmation: requestRestartConfirmationRelay.asSignal(),
            activityStyle: activityStyle,
            activity: toolbarActivityPresenter.state,
            toolbarIcon: documentState.$currentImageNode.asDriver().map { Self.toolbarIcon(for: $0) }
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
