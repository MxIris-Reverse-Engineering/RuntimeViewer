#if os(macOS)

import Foundation
import UniformTypeIdentifiers
import MemberwiseInit
import RuntimeViewerCore
import RuntimeViewerInjection
import RuntimeViewerArchitectures
import RuntimeViewerCommunication
import RuntimeViewerEngineManagement
import RuntimeViewerSettings

/// The object on screen, offered to the toolbar's share button as its interface file.
public struct SharingData {
    public let provider: NSItemProvider
    public let title: String
    public let iconType: RuntimeObjectKind
}

/// What the runtime source pickers show: the source the window is on.
public struct SwitchSourceState: Equatable {
    public let title: String
    /// The source's icon, `.runtimeEngine(engineID:)`. The view draws it as a list draws it, or as
    /// the toolbar's picker does — a machine's glyph as the symbol it is, which Xcode 27's style
    /// draws at its own size — and draws it again when an engine's icon is recorded. While the
    /// engine is gone the icon provider answers with the icon it last drew for it.
    public let icon: IconDescriptor
    public let isDisconnected: Bool
    public let selectedEngineIdentifier: String
}

public final class MainViewModel: ViewModel<MainRoute> {
    /// Bounds for the View menu's font-size commands, applied to `Settings.theme.fontSize`.
    private static let minimumFontSize: Double = 8
    private static let maximumFontSize: Double = 32

    private static let fontSizeThrottleMilliseconds: Int = 120

    @MemberwiseInit(.public)
    public struct Input {
        public let sidebarBackClick: Signal<Void>
        public let navigationPreviousClick: Signal<Void>
        public let navigationNextClick: Signal<Void>
        /// Target index into the focused tab's history, chosen from a
        /// long-press history menu on either navigation segment.
        public let navigationHistorySelected: Signal<Int>
        public let saveClick: Signal<Void>
        /// The engine identifier of a source chosen in the runtime source picker's list.
        public let switchSource: Signal<String>
        public let generationOptionsClick: Signal<Void>
        public let increaseFontSize: Signal<Void>
        public let decreaseFontSize: Signal<Void>
        public let resetFontSize: Signal<Void>
        public let loadFrameworksClick: Signal<Void>
//        let installHelperClick: Signal<Void>
        public let attachToProcessClick: Signal<Void>
        public let mcpStatusClick: Signal<Void>
        /// A click on the toolbar's activity display: the Report navigator lists the work in detail.
        public let activityClick: Signal<Void>
        public let frameworksSelected: Signal<[URL]>
        public let saveLocationSelected: Signal<URL>
        /// A choice from the runtime source picker's Dependency Cache level, for
        /// the file engine the window is on: `nil` reads the file alone.
        public let dependencyCacheSelected: Signal<RuntimeFile.DependencyCache?>
    }

    public struct Output {
        /// Everything the `TitleToolbarItem` (and the window title) shows is
        /// derived here from `DocumentState` rather than pushed in by whichever
        /// pane happens to become visible — the panes have no business owning
        /// window-level chrome, and the push model used to leave the subtitle
        /// stale whenever a reused controller rebound.
        public let windowTitle: Driver<String>
        public let toolbarTitle: Driver<String>
        public let toolbarSubtitle: Driver<String>
        public let sharingServiceData: Observable<[SharingData]>
        public let isSavable: Driver<Bool>
        public let isSidebarBackHidden: Driver<Bool>
        public let isNavigationHidden: Driver<Bool>
        public let canGoPrevious: Driver<Bool>
        public let canGoNext: Driver<Bool>
        public let navigationHistory: Driver<NavigationHistorySnapshot>
        /// What the runtime source pickers show: the source the window is on.
        public let switchSourceState: Driver<SwitchSourceState>
        /// What the runtime source picker lists when it opens.
        public let runtimeSourcePickerContent: Driver<RuntimeSourcePickerContent>
        public let attachAvailability: Driver<AttachAvailability>
        /// Load Frameworks… loads an image into the engine's process, which a
        /// file engine does not have.
        public let isLoadFrameworksEnabled: Driver<Bool>
        /// Where Load Frameworks loads, for its tooltip.
        public let loadFrameworksToolTip: Driver<String>
        public let requestFrameworkSelection: Signal<Void>
        public let requestSaveLocation: Signal<(name: String, type: UTType)>
        public let requestRestartConfirmation: Signal<Void>
        /// Where the toolbar shows the activity: the user's setting as it stands on this system,
        /// never `.automatic`.
        public let activityStyle: Driver<Settings.ToolbarActivityStyle>
        /// What the toolbar's activity display shows, in the capsule or in the window title's
        /// progress ring as `activityStyle` says. RuntimeViewerAppUI turns it into the
        /// `ToolbarActivityState` the views take.
        public let activity: Driver<ToolbarActivity>
        /// The title's icon in Xcode 27's style, which the progress ring takes the place of.
        public let toolbarIcon: Driver<TitleIcon>
    }

    /// The title's icon: the kind of the image the title names, as one glyph in one colour, as
    /// Xcode 27 draws its project icon — in the colour Xcode gives that kind of file
    /// (`RuntimeImageKind.iconColor`) — and while no image is open the app's own symbol, in blue,
    /// rather than a picture of the app icon among the glyphs. The view draws it; the app's symbol
    /// is in the app's asset catalog.
    public enum TitleIcon: Hashable, Sendable {
        case application
        case imageKind(RuntimeImageKind)
    }

    static func toolbarIcon(for imageNode: RuntimeImageNode?) -> TitleIcon {
        guard let imageNode else { return .application }
        return .imageKind(imageNode.kind)
    }

    /// One step of the history menu. An object and its Generated Interface are two steps: the title
    /// tells them apart. The icon is the object's, or for an image what it is part of.
    static func historyItem(for entry: NavigationEntry, at index: Int) -> NavigationHistoryItem {
        let icon: IconDescriptor = switch entry.content {
        case .object(let object, _):
            .runtimeObject(object.kind, size: NavigationHistorySnapshot.iconSize)
        case .image(let path):
            .imageKind(RuntimeImageKind(ofImageAt: path))
        }
        return NavigationHistoryItem(
            index: index,
            displayName: entry.showsGeneratedInterface ? "\(entry.displayName) (Generated Interface)" : entry.displayName,
            icon: icon
        )
    }

    private lazy var toolbarActivityPresenter = ToolbarActivityPresenter(documentState: documentState)

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    @RxObserved private(set) var selectedEngineIdentifier: String = RuntimeEngine.local.engineID

    private var cachedSelectedEngineName: String = RuntimeEngine.local.source.description

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
        router.trigger(.main(engine))
        selectedEngineIdentifier = engine.engineID
    }

    private let requestRestartConfirmationRelay = PublishRelay<Void>()

    public func transform(_ input: Input) -> Output {
        rx.disposeBag = DisposeBag()

        // The engine the document opened on, which is not "My Mac" for a file
        // opened from disk.
        selectedEngineIdentifier = documentState.runtimeEngine.engineID
        cachedSelectedEngineName = documentState.runtimeEngine.source.description

        let requestFrameworkSelection = input.loadFrameworksClick.asSignal()

        // Load Frameworks on My Mac opens a window of its own on a new instance
        // of the framework service, so that nothing the frameworks do lands in
        // My Mac's process and closing the window unloads them; a window
        // already on such an instance loads into it. On any other engine the
        // frameworks go into that engine's process, as they always did: a
        // framework of the shared cache an attached process borrows still goes
        // into that process, its data still coming from its owner (proposal
        // `isolated-framework-loading`).
        input.frameworksSelected.emitOnNext { [weak self] urls in
            guard let self, !urls.isEmpty else { return }
            switch documentState.runtimeEngine.source {
            case .local:
                router.trigger(.openIsolatedFrameworks(urls))
            case .file:
                break
            default:
                let frameworkLoader = documentState.frameworkLoader
                Task { await frameworkLoader.load(frameworksAt: urls) }
            }
        }.disposed(by: rx.disposeBag)

        // A refusal in a window that shows something is diagnosed in a sheet;
        // an empty framework instance window shows it in its panes instead.
        documentState.frameworkLoader.$state.asObservable()
            .distinctUntilChanged()
            .filter { state in
                if case .failed = state { return true }
                return false
            }
            .observeOnMainScheduler()
            .subscribeOnNext { [weak self] _ in
                guard let self, !documentState.frameworkLoader.showsPageInEmptyPanes else { return }
                router.trigger(.frameworkLoadFailure)
            }
            .disposed(by: rx.disposeBag)



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

        // The language the focused tab shows its object in: Save and Share write what is on
        // screen, a Generated Interface as a Swift interface.
        let focusedInterfaceLanguageObservable = documentState.$editorArea.asObservable()
            .map { $0.focusedPane.activeTab.interfaceLanguage }
            .distinctUntilChanged()

        let requestSaveLocation = input.saveClick
            .withLatestFrom(selectedRuntimeObjectSignal)
            .filterNil()
            .map { [weak self] runtimeObject in
                (name: runtimeObject.displayName, type: runtimeObject.contentType(in: self?.documentState.editorArea.focusedPane.activeTab.interfaceLanguage))
            }

        input.saveLocationSelected
            .withLatestFrom(selectedRuntimeObjectSignal) { saveLocation, selectedRuntimeObject in
                selectedRuntimeObject.map { (saveLocation, $0) }
            }
            .filterNil()
            .emitOnNext { [weak self] url, runtimeObject in
                guard let self else { return }
                var options = currentMergedGenerationOptions
                options.interfaceLanguage = documentState.editorArea.focusedPane.activeTab.interfaceLanguage
                Task {
                    do {
                        // Fetch through the interface cache with the same
                        // merged options as the content pane, so saving the
                        // visible object is a cache hit and the written text
                        // matches what the pane displays (the transformer
                        // configuration and the language participate in both).
                        let semanticString = try await self.documentState.interfaceCache.interface(for: runtimeObject, options: options)?.interfaceString
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
            guard owner.runtimeEngineManager.isFileEngineSuspended(engine),
                  let file = owner.runtimeEngineManager.file(of: engine)
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
                    try await RuntimeFileDependencyCaches.pair(engine, with: dependencyCache, runtimeEngineManager: runtimeEngineManager)
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
        let loadFrameworksToolTip = runtimeEngineOfDocument.map { engine -> String in
            switch engine.source {
            case .local: "Load Frameworks in a New Isolated Instance"
            case .frameworkInstance: "Load Frameworks into This Instance"
            default: "Load Frameworks"
            }
        }

        let sharingServiceData = Observable.combineLatest(selectedRuntimeObjectObservable, focusedInterfaceLanguageObservable)
            .map { [weak self] selected, interfaceLanguage -> [SharingData] in
                guard let self, let runtimeObjectType = selected else { return [] }

                let item = NSItemProvider()

                item.registerDataRepresentation(forTypeIdentifier: runtimeObjectType.contentType(in: interfaceLanguage).identifier, visibility: .all) { [weak self] completion in
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
                            var options = await self.currentMergedGenerationOptions
                            options.interfaceLanguage = interfaceLanguage
                            let semanticString = try await documentState.interfaceCache.interface(for: runtimeObjectType, options: options)?.interfaceString
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

        // The manager's sections. An icon that lands after them — an injected device process's,
        // which the attach sheet files once that process's engine has reported in — is drawn
        // again by the view, which follows the icon provider; the icons here are descriptions.
        let runtimeEngineSections = runtimeEngineManager.rx.runtimeEngineSections

        let switchSourceState = Driver.combineLatest(
            runtimeEngineSections,
            $selectedEngineIdentifier.asDriver()
        ).map { [weak self] sections, selectedIdentifier -> SwitchSourceState in
            let icon = IconDescriptor.runtimeEngine(engineID: selectedIdentifier)
            guard let self else {
                return SwitchSourceState(title: "RuntimeViewer", icon: icon, isDisconnected: true, selectedEngineIdentifier: selectedIdentifier)
            }
            let allEngines = sections.flatMap(\.engines)
            if let engine = allEngines.first(where: { $0.engineID == selectedIdentifier }) {
                let name = engine.source.description
                cachedSelectedEngineName = name
                return SwitchSourceState(
                    title: name,
                    icon: icon,
                    isDisconnected: false,
                    selectedEngineIdentifier: selectedIdentifier
                )
            } else {
                return SwitchSourceState(
                    title: cachedSelectedEngineName + " (Disconnected)",
                    icon: icon,
                    isDisconnected: true,
                    selectedEngineIdentifier: selectedIdentifier
                )
            }
        }

        // What the runtime source picker lists: the manager's sections with the window's source
        // checked, that source on top while its engine is gone, and the dependency caches the
        // window's file can be paired with.
        let runtimeSourcePickerContent = Driver.combineLatest(
            runtimeEngineSections,
            switchSourceState,
            runtimeEngineOfDocument
        ) { [weak self] sections, state, engineOfDocument -> RuntimeSourcePickerContent in
            guard let self else { return .empty }
            let disconnectedSource = state.isDisconnected ? RuntimeSourcePickerContent.Source(
                engineIdentifier: state.selectedEngineIdentifier,
                title: state.title,
                icon: state.icon,
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
                                icon: .runtimeEngine(engineID: engine.engineID),
                                isCurrent: engine.engineID == state.selectedEngineIdentifier
                            )
                        }
                    )
                },
                dependencyCacheChoices: RuntimeFileDependencyCaches.choices(
                    for: engineOfDocument,
                    runtimeEngineManager: runtimeEngineManager,
                    settings: settings
                )
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
            // A framework instance's window is named after its first framework
            // until an image is open, and says how its load stands.
            toolbarTitle: Driver.combineLatest(
                documentState.$runtimeEngineSession.asDriver().map(\.engine),
                currentImageName
            ).map { runtimeEngine, imageName in
                if let imageName { return imageName }
                if case .frameworkInstance(_, let frameworkURL, _) = runtimeEngine.source {
                    return frameworkURL.lastPathComponent
                }
                return "RuntimeViewer"
            },
            toolbarSubtitle: Observable.combineLatest(
                selectedRuntimeObjectObservable,
                documentState.$runtimeEngineSession.asObservable().map(\.engine),
                documentState.frameworkLoader.$state.asObservable()
            )
            .map { selectedObject, runtimeEngine, frameworkLoadState -> String in
                if let selectedObject { return selectedObject.displayName }
                guard case .frameworkInstance = runtimeEngine.source else { return "" }
                switch frameworkLoadState {
                case .idle: return "Isolated"
                case .loading: return "Loading…"
                case .failed: return "Couldn't Load"
                case .instanceStopped: return "Stopped"
                }
            }
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
                    items: history.entries.enumerated().map { entryIndex, entry in
                        Self.historyItem(for: entry, at: entryIndex)
                    },
                    currentIndex: history.currentIndex ?? -1
                )
            },
            switchSourceState: switchSourceState,
            runtimeSourcePickerContent: runtimeSourcePickerContent,
            attachAvailability: attachAvailability,
            isLoadFrameworksEnabled: isLoadFrameworksEnabled,
            loadFrameworksToolTip: loadFrameworksToolTip,
            requestFrameworkSelection: requestFrameworkSelection,
            requestSaveLocation: requestSaveLocation,
            requestRestartConfirmation: requestRestartConfirmationRelay.asSignal(),
            activityStyle: activityStyle,
            activity: toolbarActivityPresenter.activity,
            toolbarIcon: documentState.$currentImageNode.asDriver().map { Self.toolbarIcon(for: $0) }
        )
    }
}

extension UTType {
    fileprivate static let swiftInterface: Self = .init(filenameExtension: "swiftinterface") ?? .swiftSource
}

extension RuntimeObject {
    /// The file type of the object's interface in `interfaceLanguage`: a Swift interface for a Swift
    /// object and for an Objective-C one shown as Swift imports it, a C++ header for a C++ object, a
    /// C header otherwise.
    fileprivate func contentType(in interfaceLanguage: RuntimeInterfaceLanguage?) -> UTType {
        if interfaceLanguage == .swift {
            return .swiftInterface
        }
        switch kind {
        case .c,
             .objc:
            return .cHeader
        case .swift:
            return .swiftInterface
        case .cPlusPlus:
            return .cPlusPlusHeader
        }
    }
}

#endif
