import AppKit
import RuntimeViewerCore
import UniformTypeIdentifiers
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

class MainViewModel: ViewModel<MainRoute> {
    struct Input {
        let sidebarBackClick: Signal<Void>
        let contentBackClick: Signal<Void>
        let saveClick: Signal<Void>
        let switchSource: Signal<Int>
        let generationOptionsClick: Signal<NSView>
        let fontSizeSmallerClick: Signal<Void>
        let fontSizeLargerClick: Signal<Void>
        let loadFrameworksClick: Signal<Void>
        let installHelperClick: Signal<Void>
        let attachToProcessClick: Signal<Void>
    }

    struct Output {
        let sharingServiceItems: Observable<[Any]>
        let isSavable: Driver<Bool>
        let isSidebarBackHidden: Driver<Bool>
        let runtimeSources: Driver<[RuntimeSource]>
        let selectedRuntimeSourceIndex: Driver<Int>
    }

    var completeTransition: Observable<SidebarRoute>? {
        didSet {
            completeTransitionDisposable?.dispose()
            completeTransitionDisposable = completeTransition?.map { if case .selectedObject(let runtimeObject) = $0 { runtimeObject } else { nil } }.bind(to: $selectedRuntimeObject)
        }
    }

    var completeTransitionDisposable: Disposable?

    let selectedRuntimeSourceIndex = BehaviorRelay(value: 0)

    @Observed
    var selectedRuntimeObject: RuntimeObjectName?

    func transform(_ input: Input) -> Output {
        rx.disposeBag = DisposeBag()

        input.loadFrameworksClick.emitOnNext { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let openPanel = NSOpenPanel()
                openPanel.allowedContentTypes = [.framework]
                openPanel.allowsMultipleSelection = true
                openPanel.canChooseDirectories = true
                let result = await openPanel.begin()
                guard result == .OK else { return }
                for url in openPanel.urls {
                    do {
                        try Bundle(url: url)?.loadAndReturnError()
                        await self.appServices.runtimeEngine.reloadData()
                    } catch {
                        print(error)
                        NSAlert(error: error).runModal()
                    }
                }
            }
        }
        .disposed(by: rx.disposeBag)
        input.installHelperClick.emitOnNext { [weak self] in
            guard let self else { return }
            Task {
                do {
                    try await RuntimeHelperClient.shared.install()
                } catch {
                    print(error)
                    self.errorRelay.accept(error)
                }
            }
        }
        .disposed(by: rx.disposeBag)

        input.fontSizeSmallerClick.emitOnNext {
            AppDefaults[\.themeProfile].fontSizeSmaller()
        }
        .disposed(by: rx.disposeBag)
        input.fontSizeLargerClick.emitOnNext {
            AppDefaults[\.themeProfile].fontSizeLarger()
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
        input.saveClick.withLatestFrom($selectedRuntimeObject.asSignalOnErrorJustComplete()).filterNil()
            .emitOnNext { [weak self] runtimeObject in
                guard let self else { return }
                Task { @MainActor in
                    let savePanel = NSSavePanel()
                    savePanel.allowedContentTypes = [runtimeObject.contentType]
                    savePanel.nameFieldStringValue = runtimeObject.displayName
                    let result = await savePanel.begin()
                    guard result == .OK, let url = savePanel.url else { return }
                    Task {
                        do {
                            let semanticString = try await self.appServices.runtimeEngine.interface(for: runtimeObject, options: .init(objcHeaderOptions: AppDefaults[\.options], swiftDemangleOptions: .default))?.interfaceString
                            try semanticString?.string.write(to: url, atomically: true, encoding: .utf8)
                        } catch {
                            print(error)
                        }
                    }
                }
            }
            .disposed(by: rx.disposeBag)
        input.switchSource.emit(with: self) {
            $0.router.trigger(.main(RuntimeEngineManager.shared.runtimeEngines[$1]))
            $0.selectedRuntimeSourceIndex.accept($1)
        }.disposed(by: rx.disposeBag)

        let sharingServiceItems = completeTransition?.map { [weak self] router -> [Any] in
            guard let self else { return [] }
            switch router {
            case .selectedObject(let runtimeObjectType):
                let item = NSItemProvider()
                item.registerDataRepresentation(forTypeIdentifier: runtimeObjectType.contentType.identifier, visibility: .all) { completion in
                    Task {
                        do {
                            let semanticString = try await self.appServices.runtimeEngine.interface(for: runtimeObjectType, options: .init(objcHeaderOptions: AppDefaults[\.options], swiftDemangleOptions: .default))?.interfaceString
                            completion(semanticString?.string.data(using: .utf8), nil)
                        } catch {
                            completion(nil, error)
                        }
                    }
                    return nil
                }
                let icon: NSImage
                let fileExtension: String
                switch runtimeObjectType.kind {
                case .c, .objc:
                    fileExtension = "h"
                    icon = NSWorkspace.shared.icon(for: .cHeader)
                case .swift:
                    fileExtension = "swiftinterface"
                    icon = NSWorkspace.shared.icon(for: .swiftSource)
                }
                let previewItem = NSPreviewRepresentingActivityItem(item: item, title: runtimeObjectType.displayName + "." + fileExtension, image: nil, icon: icon)
                return [previewItem]
            default:
                return []
            }
        }

        return Output(
            sharingServiceItems: sharingServiceItems ?? .empty(),
            isSavable: $selectedRuntimeObject.asDriver().map { $0 != nil },
            isSidebarBackHidden: completeTransition?.map {
                if case .clickedNode = $0 { false } else if case .selectedObject = $0 { false } else { true }
            }.asDriver(onErrorJustReturn: true) ?? .empty(),
            runtimeSources: RuntimeEngineManager.shared.rx.runtimeEngines.map { $0.map { $0.source } },
            selectedRuntimeSourceIndex: selectedRuntimeSourceIndex.asDriver()
        )
    }
}

extension UTType {
    fileprivate static let swiftInterface: Self = .init(filenameExtension: "swiftinterface") ?? .swiftSource
}

extension RuntimeObjectName {
    fileprivate var contentType: UTType {
        switch kind {
        case .c, .objc:
            return .cHeader
        case .swift:
            return .swiftInterface
        }
    }
}
