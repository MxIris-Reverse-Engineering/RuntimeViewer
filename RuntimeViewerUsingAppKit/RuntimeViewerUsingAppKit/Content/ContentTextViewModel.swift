//
//  ContentTextViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/8.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

class ContentTextViewModel: ViewModel<ContentRoute> {
    @Observed
    var theme: ThemeProfile

    @Observed
    var runtimeObject: RuntimeObjectType

    @Observed
    var attributedString: NSAttributedString?

    init(runtimeObject: RuntimeObjectType, appServices: AppServices, router: UnownedRouter<ContentRoute>) {
        self.runtimeObject = runtimeObject
        self.theme = XcodeDarkTheme()
        super.init(appServices: appServices, router: router)
        setAttributedString(for: AppDefaults[\.options])
        AppDefaults[\.$options].asSignalOnErrorJustComplete().emit(with: self, onNext: {
            $0.setAttributedString(for: $1)
        }).disposed(by: rx.disposeBag)
    }

    struct Input {}
    
    struct Output {
        let attributedString: Driver<NSAttributedString>
        let theme: Driver<ThemeProfile>
    }

    func setAttributedString(for options: CDGenerationOptions) {
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

    func transform(_ input: Input) -> Output {
        return Output(
            attributedString: $attributedString.asDriver().compactMap { $0 },
            theme: $theme.asDriver()
        )
    }
}


extension RuntimeObjectType {
    @MainActor
    func semanticString(for options: CDGenerationOptions) -> CDSemanticString? {
        switch self {
        case let .class(named):
            if let cls = NSClassFromString(named) {
                let classModel = CDClassModel(with: cls)
                return classModel.semanticLines(with: options)
            } else {
                return nil
            }
        case let .protocol(named):
            if let proto = NSProtocolFromString(named) {
                let protocolModel = CDProtocolModel(with: proto)
                return protocolModel.semanticLines(with: options)
            } else {
                return nil
            }
        }
    }
}
