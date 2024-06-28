#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

public class ContentTextViewModel: ViewModel<ContentRoute> {
    @Observed
    private var theme: ThemeProfile

    @Observed
    private var runtimeObject: RuntimeObjectType

    @Observed
    private var attributedString: NSAttributedString?

    public init(runtimeObject: RuntimeObjectType, appServices: AppServices, router: any Router<ContentRoute>) {
        self.runtimeObject = runtimeObject
        self.theme = XcodePresentationTheme()
        super.init(appServices: appServices, router: router)
        setAttributedString(for: AppDefaults[\.options])
        AppDefaults[\.$options].asSignalOnErrorJustComplete().emit(with: self, onNext: {
            $0.setAttributedString(for: $1)
        }).disposed(by: rx.disposeBag)
    }

    public struct Input {
        public let runtimeObjectClicked: Signal<RuntimeObjectType>
        public init(runtimeObjectClicked: Signal<RuntimeObjectType>) {
            self.runtimeObjectClicked = runtimeObjectClicked
        }
    }
    
    public struct Output {
        public let attributedString: Driver<NSAttributedString>
        public let runtimeObjectName: Driver<String>
        public let theme: Driver<ThemeProfile>
    }

    private func setAttributedString(for options: CDGenerationOptions) {
        switch runtimeObject {
        case let .class(named):
            if let cls = NSClassFromString(named) {
                let classModel = CDClassModel(with: cls)
                attributedString = classModel.semanticLines(with: options).attributedString(for: theme)
            } else {
                attributedString = NSAttributedString {
                    AText("\(named) class not found.")
                }
            }
        case let .protocol(named):
            if let proto = NSProtocolFromString(named) {
                let protocolModel = CDProtocolModel(with: proto)
                attributedString = protocolModel.semanticLines(with: options).attributedString(for: theme)
            } else {
                attributedString = NSAttributedString {
                    AText("\(named) protocol not found.")
                }
            }
        }
    }

    public func transform(_ input: Input) -> Output {
        input.runtimeObjectClicked.emit(with: self) { $0.router.trigger(.next($1)) }.disposed(by: rx.disposeBag)
        return Output(
            attributedString: $attributedString.asDriver().compactMap { $0 },
            runtimeObjectName: $runtimeObject.asDriver().map { $0.name },
            theme: $theme.asDriver()
        )
    }
}
