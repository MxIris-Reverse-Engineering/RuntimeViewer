#if os(macOS)

import Foundation
import MemberwiseInit
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings

public typealias GenerationOptionsMutation = (inout RuntimeObjectInterface.GenerationOptions) -> Void

/// One image's Generation Options, in the sheet Editor › Generation Options for “<image>”… opens
/// (proposal `generation-options-image-overrides`).
///
/// It shows the options the image prints with — the global ones, with those the image overrides
/// replaced — and marks the overridden ones. A change is recorded as the image's override, or takes
/// the override away when it sets the global value again; reverting an option, or every option,
/// puts it back on the global ones. Global Options… opens Settings › Generation Options. Everything
/// follows the settings, so a change made there while the sheet is open shows at once.
public final class ImageGenerationOptionsViewModel: ViewModel<MainRoute> {
    @MemberwiseInit(.public)
    public struct Input {
        public let updateOption: Signal<GenerationOptionsMutation>
        public let revertOption: Signal<Settings.GenerationOption>
        public let revertAll: Signal<Void>
        public let showGlobalOptions: Signal<Void>
        public let done: Signal<Void>
    }

    public struct Output {
        /// The image's name.
        public let title: Driver<String>
        /// The engine's name.
        public let subtitle: Driver<String>
        /// The options the image prints with.
        public let options: Driver<RuntimeObjectInterface.GenerationOptions>
        /// The options the image overrides.
        public let overriddenOptions: Driver<Set<Settings.GenerationOption>>
        /// Whether the image overrides any option.
        public let canRevertAll: Driver<Bool>
    }

    /// The image, as the document names it.
    public let imagePath: String

    /// The options the image prints with now.
    @RxObserved
    public private(set) var effectiveOptions: RuntimeObjectInterface.GenerationOptions = RuntimeObjectInterface.GenerationOptions()

    /// The options the image overrides now.
    @RxObserved
    public private(set) var overriddenOptions: Set<Settings.GenerationOption> = []

    public init(imagePath: String, documentState: DocumentState, router: any Router<MainRoute>) {
        self.imagePath = imagePath
        super.init(documentState: documentState, router: router)

        let runtimeEngine = documentState.runtimeEngine
        settings.generationOptionsSettingsObservable()
            .map { generationOptionsSettings in
                (
                    generationOptionsSettings.effectiveOptions(forImageAt: imagePath, in: runtimeEngine),
                    generationOptionsSettings.override(forImageAt: imagePath, in: runtimeEngine)?.overriddenOptions ?? []
                )
            }
            .subscribeOnNext { [weak self] effectiveOptions, overriddenOptions in
                guard let self else { return }
                MainActor.assumeIsolated {
                    if self.effectiveOptions != effectiveOptions {
                        self.effectiveOptions = effectiveOptions
                    }
                    if self.overriddenOptions != overriddenOptions {
                        self.overriddenOptions = overriddenOptions
                    }
                }
            }
            .disposed(by: rx.disposeBag)
    }

    public func transform(_ input: Input) -> Output {
        input.updateOption
            .emitOnNext { [weak self] mutation in
                guard let self else { return }
                settings.generationOptions.updateOverride(forImageAt: imagePath, in: documentState.runtimeEngine, mutation)
            }
            .disposed(by: rx.disposeBag)

        input.revertOption
            .emitOnNext { [weak self] option in
                guard let self else { return }
                settings.generationOptions.revert(option, forImageAt: imagePath, in: documentState.runtimeEngine)
            }
            .disposed(by: rx.disposeBag)

        input.revertAll
            .emitOnNext { [weak self] in
                guard let self else { return }
                settings.generationOptions.removeOverride(forImageAt: imagePath, in: documentState.runtimeEngine)
            }
            .disposed(by: rx.disposeBag)

        input.showGlobalOptions
            .emitOnNext { [weak self] in
                guard let self else { return }
                appRouter.trigger(.settingsPage(.generationOptions))
            }
            .disposed(by: rx.disposeBag)

        input.done
            .emitOnNext { [weak self] in
                guard let self else { return }
                router.trigger(.dismiss)
            }
            .disposed(by: rx.disposeBag)

        return Output(
            title: .just(NavigationEntry.imageName(ofImageAt: imagePath)),
            subtitle: .just(documentState.runtimeEngine.source.description),
            options: $effectiveOptions.asDriver(),
            overriddenOptions: $overriddenOptions.asDriver(),
            canRevertAll: $overriddenOptions.asDriver().map { !$0.isEmpty }
        )
    }
}

#endif
