#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit
import Dependencies

public final class ContentTextViewModel: ViewModel<ContentRoute> {
    @Observed
    public private(set) var theme: ThemeProfile

    @Observed
    public private(set) var runtimeObject: RuntimeObject

    @Observed
    public private(set) var imageNameOfRuntimeObject: String?

    @Observed
    public private(set) var attributedString: NSAttributedString?

    public init(runtimeObject: RuntimeObject, appServices: AppServices, router: any Router<ContentRoute>) {
        self.runtimeObject = runtimeObject
        self.theme = XcodePresentationTheme()
        super.init(appServices: appServices, router: router)

        self.imageNameOfRuntimeObject = runtimeObject.imageName

        Observable.combineLatest($runtimeObject, appDefaults.$options, appDefaults.$themeProfile)
            .flatMapLatest { [unowned self] runtimeObject, options, theme in
                Observable.async {
                    try await self.appServices.runtimeEngine.interface(for: runtimeObject, options: options).map { ($0.interfaceString, theme, runtimeObject) }
                }
                .trackActivity(_commonLoading)
            }
            .catchAndReturn(nil)
            .observeOnMainScheduler()
            .map { $0.map { $0.attributedString(for: $1, runtimeObjectName: $2) } }
            .bind(to: $attributedString)
            .disposed(by: rx.disposeBag)
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let runtimeObjectClicked: Signal<RuntimeObject>
    }

    public struct Output {
        public let attributedString: Driver<NSAttributedString>
        public let runtimeObjectName: Driver<String>
        public let theme: Driver<ThemeProfile>
        public let imageNameOfRuntimeObject: Driver<String?>
        public let runtimeObjectNotFound: Signal<Void>
    }

    public func transform(_ input: Input) -> Output {
        let runtimeObjectNotFoundRelay = PublishRelay<Void>()
        
        input.runtimeObjectClicked
            .flatMapLatest { [unowned self] runtimeObject in
                Observable.async {
                    try await self.appServices.runtimeEngine.interface(for: runtimeObject, options: .init())
                }
                .trackActivity(_commonLoading)
                .asSignal(onErrorJustReturn: nil)
            }
            .emit(with: self) { target, interface in
                Task { @MainActor in
                    if let interface {
                        target.router.trigger(.next(interface.object))
                    } else {
                        runtimeObjectNotFoundRelay.accept()
                    }
                }
            }
            .disposed(by: rx.disposeBag)
        
        return Output(
            attributedString: $attributedString.asDriver().compactMap { $0 },
            runtimeObjectName: $runtimeObject.asDriver().map { $0.displayName },
            theme: $theme.asDriver(),
            imageNameOfRuntimeObject: $imageNameOfRuntimeObject.asDriver(),
            runtimeObjectNotFound: runtimeObjectNotFoundRelay.asSignal()
        )
    }
}

extension NSAttributedString: @unchecked @retroactive Sendable {}
