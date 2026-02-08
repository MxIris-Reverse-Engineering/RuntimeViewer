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


final class MainViewModel: ViewModel<MainRoute> {
    struct Input {
        let sidebarBackClick: Signal<Void>
        let contentBackClick: Signal<Void>
        let saveClick: Signal<Void>
        let switchSource: Signal<Int>
        let generationOptionsClick: Signal<NSView>
        let fontSizeSmallerClick: Signal<Void>
        let fontSizeLargerClick: Signal<Void>
        let loadFrameworksClick: Signal<Void>
//        let installHelperClick: Signal<Void>
        let attachToProcessClick: Signal<Void>
        let frameworksSelected: Signal<[URL]>
        let saveLocationSelected: Signal<URL>
    }

    struct Output {
        let sharingServiceData: Observable<[SharingData]>
        let isSavable: Driver<Bool>
        let isSidebarBackHidden: Driver<Bool>
        let isContentBackHidden: Driver<Bool>
        let runtimeSources: Driver<[RuntimeSource]>
        let selectedRuntimeSourceIndex: Driver<Int>
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

    let selectedRuntimeSourceIndex = BehaviorRelay(value: 0)

    @Observed
    var selectedRuntimeObject: RuntimeObject?

    private let requestRestartConfirmationRelay = PublishRelay<Void>()

    func transform(_ input: Input) -> Output {
        rx.disposeBag = DisposeBag()

        let requestFrameworkSelection = input.loadFrameworksClick.asSignal()

        input.frameworksSelected.emit(onNext: { [weak self] urls in
            guard let self = self else { return }
            Task { @MainActor in
                for url in urls {
                    do {
                        try Bundle(url: url)?.loadAndReturnError()
                        await self.appState.runtimeEngine.reloadData(isReloadImageNodes: false)
                    } catch {
                        self.errorRelay.accept(error) // 统一错误处理
                    }
                }
            }
        }).disposed(by: rx.disposeBag)

        

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
        
        let requestSaveLocation = input.saveClick
            .withLatestFrom($selectedRuntimeObject.asSignalOnErrorJustComplete())
            .filterNil()
            .map { (name: $0.displayName, type: $0.contentType) }

        input.saveLocationSelected
            .withLatestFrom($selectedRuntimeObject.asSignalOnErrorJustComplete()) { saveLocation, selectedRuntimeObject in
                selectedRuntimeObject.map { (saveLocation, $0) }
            }
            .filterNil()
            .emit(onNext: { [weak self] url, runtimeObject in
                guard let self = self else { return }
                Task {
                    do {
                        let semanticString = try await self.appState.runtimeEngine.interface(for: runtimeObject, options: self.appDefaults.options)?.interfaceString
                        try semanticString?.string.write(to: url, atomically: true, encoding: .utf8)
                    } catch {
                        self.errorRelay.accept(error)
                    }
                }
            }).disposed(by: rx.disposeBag)

        input.switchSource.emit(with: self) {
            $0.router.trigger(.main($0.runtimeEngineManager.runtimeEngines[$1]))
            $0.selectedRuntimeSourceIndex.accept($1)
        }.disposed(by: rx.disposeBag)

        let sharingServiceData = completeTransition?.map { [weak self] router -> [SharingData] in
            guard let self = self, case .selectedObject(let runtimeObjectType) = router else { return [] }
            
            let item = NSItemProvider()
            
            item.registerDataRepresentation(forTypeIdentifier: runtimeObjectType.contentType.identifier, visibility: .all) { [weak self] completion in
                guard let self else {
                    completion(nil, nil)
                    return nil
                }
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        let semanticString = try await appState.runtimeEngine.interface(for: runtimeObjectType, options: self.appDefaults.options)?.interfaceString
                        completion(semanticString?.string.data(using: .utf8), nil)
                    } catch {
                        completion(nil, error)
                    }
                }
                return nil
            }
            
            return [SharingData(provider: item, title: runtimeObjectType.displayName, iconType: runtimeObjectType.kind)]
        }

        return Output(
            sharingServiceData: sharingServiceData ?? .empty(),
            isSavable: $selectedRuntimeObject.asDriver().map { $0 != nil },
            isSidebarBackHidden: completeTransition?.map { if $0.isClickedNode || $0.isSelectedObject { false } else { true } }.asDriver(onErrorJustReturn: true) ?? .empty(),
            isContentBackHidden: isContentStackDepthGreaterThanOne.map {
                !$0
            }.asDriver(onErrorJustReturn: true),
            runtimeSources: runtimeEngineManager.rx.runtimeEngines.map { $0.map { $0.source } },
            selectedRuntimeSourceIndex: selectedRuntimeSourceIndex.asDriver(),
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
