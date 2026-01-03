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
    public private(set) var runtimeObject: RuntimeObjectName

    @Observed
    public private(set) var imageNameOfRuntimeObject: String?

    @Observed
    public private(set) var attributedString: NSAttributedString?

    @Dependency(\.appDefaults)
    private var appDefaults

    public init(runtimeObject: RuntimeObjectName, appServices: AppServices, router: any Router<ContentRoute>) {
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
        public let runtimeObjectClicked: Signal<RuntimeObjectName>
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
            .emit(with: self) { target, runtimeObjectName in
                Task { @MainActor in
                    if let interface = try await target.appServices.runtimeEngine.interface(for: runtimeObjectName, options: .init()) {
                        target.router.trigger(.next(interface.name))
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
