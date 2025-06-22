#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import Demangle
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

public class ContentTextViewModel: ViewModel<ContentRoute> {
    @Observed
    public private(set) var theme: ThemeProfile

    @Observed
    public private(set) var runtimeObject: RuntimeObjectName

    @Observed
    public private(set) var imageNameOfRuntimeObject: String?
    
    @Observed
    public private(set) var attributedString: NSAttributedString?

    public init(runtimeObject: RuntimeObjectName, appServices: AppServices, router: any Router<ContentRoute>) {
        self.runtimeObject = runtimeObject
        self.theme = XcodePresentationTheme()
        super.init(appServices: appServices, router: router)
        
        imageNameOfRuntimeObject = runtimeObject.imageName
        
        Observable.combineLatest($runtimeObject, AppDefaults[\.$options], AppDefaults[\.$themeProfile])
            .flatMapLatest { [unowned self] runtimeObject, options, theme in
                Observable.async {
                    try await self.appServices.runtimeEngine.interface(for: runtimeObject, options: .init(objcHeaderOptions: options, swiftDemangleOptions: .interface)).map { ($0.interfaceString, theme, runtimeObject) }
                }
                .trackActivity(_commonLoading)
            }
            .catchAndReturn(nil)
            .observeOnMainScheduler()
            .map { $0.map { $0.attributedString(for: $1, runtimeObject: $2) } }
            .bind(to: $attributedString)
            .disposed(by: rx.disposeBag)
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let runtimeObjectClicked: Signal<RuntimeObjectName>
    }

    public struct Output {
        public let attributedString: Driver<NSAttributedString>
        public let runtimeObjectName: Driver<String>
        public let theme: Driver<ThemeProfile>
        public let imageNameOfRuntimeObject: Driver<String?>
    }

//    private func setAttributedString(for options: CDGenerationOptions) {
//        switch runtimeObject {
//        case let .class(named):
//            if let cls = NSClassFromString(named) {
//                let classModel = CDClassModel(with: cls)
//                attributedString = classModel.semanticLines(with: options).attributedString(for: theme)
//            } else {
//                attributedString = NSAttributedString {
//                    AText("\(named) class not found.")
//                }
//            }
//        case let .protocol(named):
//            if let proto = NSProtocolFromString(named) {
//                let protocolModel = CDProtocolModel(with: proto)
//                attributedString = protocolModel.semanticLines(with: options).attributedString(for: theme)
//            } else {
//                attributedString = NSAttributedString {
//                    AText("\(named) protocol not found.")
//                }
//            }
//        }
//    }

    public func transform(_ input: Input) -> Output {
        input.runtimeObjectClicked.emit(with: self) { $0.router.trigger(.next($1)) }.disposed(by: rx.disposeBag)
        return Output(
            attributedString: $attributedString.asDriver().compactMap { $0 },
            runtimeObjectName: $runtimeObject.asDriver().map { $0.name },
            theme: $theme.asDriver(),
            imageNameOfRuntimeObject: $imageNameOfRuntimeObject.asDriver()
        )
    }
}

extension NSAttributedString: @unchecked @retroactive Sendable {}
