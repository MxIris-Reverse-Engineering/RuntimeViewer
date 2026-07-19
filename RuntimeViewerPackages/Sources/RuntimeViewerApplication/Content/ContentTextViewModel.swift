#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
@preconcurrency import RuntimeViewerSettings
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

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<ContentRoute>) {
        self.runtimeObject = runtimeObject
        self.theme = ResolvedTheme.fallback
        super.init(documentState: documentState, router: router)

        self.imageNameOfRuntimeObject = runtimeObject.imageName

        let transformerObservable: Observable<Transformer.Configuration>
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        transformerObservable = Observable<Transformer.Configuration>
            .tracking {
                @Dependency(\.settings) var settings
                return settings.transformer
            }
            .share(replay: 1, scope: .whileConnected)
        #else
        transformerObservable = .just(.init())
        #endif

        let themeObservable: Observable<ThemeProfile>
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // The shared stream multicasts a single `Observable.tracking` chain
        // across every document, so editing any custom preset only rebuilds
        // `ResolvedTheme` once instead of once per open document. Equatable
        // dedup happens upstream so the downstream `combineLatest` only
        // re-runs the engine `interface(for:)` fetch on a real change.
        @Dependency(\.resolvedThemeStream) var resolvedThemeStream
        themeObservable = resolvedThemeStream.observable.map { $0 as ThemeProfile }
        #else
        themeObservable = .just(ResolvedTheme.fallback)
        #endif

        themeObservable
            .observeOnMainScheduler()
            .bind(to: $theme)
            .disposed(by: rx.disposeBag)

        Observable.combineLatest($runtimeObject, appDefaults.$options, themeObservable, transformerObservable)
            .flatMapLatest { [unowned self] runtimeObject, options, theme, transformer in
                var mergedOptions = options
                mergedOptions.transformer = transformer
                return Observable.async {
                    try await self.documentState.runtimeEngine.interface(for: runtimeObject, options: mergedOptions).map { ($0.interfaceString, theme, runtimeObject) }
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
        public let theme: Driver<ThemeProfile>
        public let imageNameOfRuntimeObject: Driver<String?>
        public let runtimeObjectNotFound: Signal<Void>
    }

    public func transform(_ input: Input) -> Output {
        let runtimeObjectNotFoundRelay = PublishRelay<Void>()
        
        input.runtimeObjectClicked
            .flatMapLatest { [unowned self] runtimeObject in
                Observable.async {
                    try await self.documentState.runtimeEngine.interface(for: runtimeObject, options: .init())
                }
                .trackActivity(_commonLoading)
                .asSignal(onErrorJustReturn: nil)
            }
            .emit(with: self) { target, interface in
                if let interface {
                    target.documentState.selectionRouter.trigger(.push(interface.object))
                } else {
                    runtimeObjectNotFoundRelay.accept(())
                }
            }
            .disposed(by: rx.disposeBag)
        
        return Output(
            attributedString: $attributedString.asDriver().compactMap { $0 },
            theme: $theme.asDriver(),
            imageNameOfRuntimeObject: $imageNameOfRuntimeObject.asDriver(),
            runtimeObjectNotFound: runtimeObjectNotFoundRelay.asSignal()
        )
    }
}

extension NSAttributedString: @unchecked @retroactive Sendable {}
