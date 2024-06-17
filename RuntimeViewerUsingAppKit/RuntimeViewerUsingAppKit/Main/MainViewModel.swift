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

class MainViewModel: ViewModel<MainRoute> {
    struct Input {
        let sidebarBackClick: Signal<Void>
        let saveClick: Signal<Void>
    }

    struct Output {
        let sharingServiceItems: Observable<[Any]>
        let isSavable: Driver<Bool>
    }

    let completeTransition: Observable<SidebarRoute>

    func transform(_ input: Input) -> Output {
        input.sidebarBackClick.emit(to: router.rx.trigger(.sidebarBack)).disposed(by: rx.disposeBag)
        let sharingServiceItems = completeTransition.map { router -> [Any] in
            switch router {
            case let .selectedObject(runtimeObjectType):
                let runtimeObjectItem = RuntimeObjectItem(runtimeObject: runtimeObjectType, options: AppDefaults[\.options])
                let item = NSItemProvider(object: runtimeObjectItem)
//                item.registerFileRepresentation(forTypeIdentifier: UTType.cHeader.identifier, fileOptions: [], visibility: .all) { completion in
//                    do {
//                        let url = try runtimeObjectItem.writeToTemporary()
//                        completion(url, true, nil)
//                    } catch {
//                        completion(nil, true, error)
//                    }
//                    
//                    return nil
//                }
                
                if #available(macOS 13.0, *) {
                    let icon = NSWorkspace.shared.icon(for: .cHeader)
                    let previewItem = NSPreviewRepresentingActivityItem(item: item, title: runtimeObjectItem.fileName, image: nil, icon: icon)
                    return [previewItem]
                } else {
                    return [item]
                }
//                return [try? runtimeObjectItem.writeToTemporary() as Any]
            default:
                return []
            }
        }
        
        return Output(
            sharingServiceItems: sharingServiceItems,
            isSavable: completeTransition.map { if case .selectedObject = $0 { true } else { false } }.asDriver(onErrorJustReturn: false)
        )
    }

    init(appServices: AppServices, router: UnownedRouter<MainRoute>, completeTransition: Observable<SidebarRoute>) {
        self.completeTransition = completeTransition
        super.init(appServices: appServices, router: router)
    }
}


class RuntimeObjectItem: NSObject, NSItemProviderWriting {
    
    static var writableTypeIdentifiersForItemProvider: [String] { [UTType.cHeader.identifier] }
    
    let runtimeObject: RuntimeObjectType
    
    let options: CDGenerationOptions
    
    var stringValue: String? {
        runtimeObject.semanticString(for: options)?.string()
    }
    
    init(runtimeObject: RuntimeObjectType, options: CDGenerationOptions) {
        self.runtimeObject = runtimeObject
        self.options = options
    }
    
    func loadData(withTypeIdentifier typeIdentifier: String, forItemProviderCompletionHandler completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void) -> Progress? {
        completionHandler(stringValue?.data(using: .utf8), nil)
        return nil
    }
    
    func write(toFile file: String) throws {
        try stringValue?.write(toFile: file, atomically: true, encoding: .utf8)
    }
    
    func write(to url: URL) throws {
        try stringValue?.write(to: url, atomically: true, encoding: .utf8)
    }
    
    var fileName: String {
        runtimeObject.name + ".h"
    }
    
    func writeToTemporary() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        try write(to: url)
        return url
    }
}
