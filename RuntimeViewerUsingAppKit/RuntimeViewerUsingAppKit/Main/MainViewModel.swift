//
//  MainViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/4.
//

import AppKit
import RuntimeViewerCore
import UniformTypeIdentifiers
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class MainViewModel: ViewModel<MainRoute> {
    struct Input {
        let sidebarBackClick: Signal<Void>
        let saveClick: Signal<Void>
        let switchSource: Signal<Int>
        let generationOptionsClick: Signal<NSView>
    }

    struct Output {
        let sharingServiceItems: Observable<[Any]>
        let isSavable: Driver<Bool>
    }

    let completeTransition: Observable<SidebarRoute>

    @Observed
    var selectedRuntimeObject: RuntimeObjectType?

    func transform(_ input: Input) -> Output {
        input.sidebarBackClick.emit(to: router.rx.trigger(.sidebarBack)).disposed(by: rx.disposeBag)
        input.generationOptionsClick.emit(with: self) { $0.router.trigger(.generationOptions(sender: $1)) }.disposed(by: rx.disposeBag)
        input.saveClick.withLatestFrom($selectedRuntimeObject.asSignalOnErrorJustComplete()).filterNil()
            .emitOnNext { runtimeObject in
                Task { @MainActor in
                    let savePanel = NSSavePanel()
                    savePanel.allowedContentTypes = [.cHeader]
                    savePanel.nameFieldStringValue = runtimeObject.name
                    let result = await savePanel.begin()
                    guard result == .OK, let url = savePanel.url else { return }
                    Task {
                        do {
                            let semanticString = try await self.appServices.runtimeListings.semanticString(for: runtimeObject, options: AppDefaults[\.options])
                            try semanticString.string().write(to: url, atomically: true, encoding: .utf8)
                        } catch {
                            print(error)
                        }
                    }
                }
            }
            .disposed(by: rx.disposeBag)

        input.switchSource.emit(with: self) { $0.router.trigger(.main($1 == .zero ? .shared : .macCatalystReceiver)) }.disposed(by: rx.disposeBag)

        let sharingServiceItems = completeTransition.map { router -> [Any] in
            switch router {
            case let .selectedObject(runtimeObjectType):
                let item = NSItemProvider()
                item.registerDataRepresentation(forTypeIdentifier: UTType.cHeader.identifier, visibility: .all) { [weak self] completion in
                    guard let self else {
                        completion(nil, CocoaError.error(.featureUnsupported))
                        return nil
                    }
                    Task {
                        do {
                            let semanticString = try await self.appServices.runtimeListings.semanticString(for: runtimeObjectType, options: AppDefaults[\.options])
                            completion(semanticString.string().data(using: .utf8), nil)
                        } catch {
                            completion(nil, error)
                        }
                    }
                    return nil
                }
                if #available(macOS 13.0, *) {
                    let icon = NSWorkspace.shared.icon(for: .cHeader)
                    let previewItem = NSPreviewRepresentingActivityItem(item: item, title: runtimeObjectType.name + ".h", image: nil, icon: icon)
                    return [previewItem]
                } else {
                    return [item]
                }
            default:
                return []
            }
        }

        return Output(
            sharingServiceItems: sharingServiceItems,
            isSavable: $selectedRuntimeObject.asDriver().map { $0 != nil }
        )
    }

    init(appServices: AppServices, router: any Router<MainRoute>, completeTransition: Observable<SidebarRoute>) {
        self.completeTransition = completeTransition
        super.init(appServices: appServices, router: router)
        completeTransition.map { if case let .selectedObject(runtimeObject) = $0 { runtimeObject } else { nil } }.bind(to: $selectedRuntimeObject).disposed(by: rx.disposeBag)
    }
}
