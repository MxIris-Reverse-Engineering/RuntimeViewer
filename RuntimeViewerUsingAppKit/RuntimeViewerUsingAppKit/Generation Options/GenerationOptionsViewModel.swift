import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import Dependencies
import RuntimeViewerCore

typealias OptionKeyPath = WritableKeyPath<RuntimeObjectInterface.GenerationOptions, Bool>
typealias OptionsMutation = (inout RuntimeObjectInterface.GenerationOptions) -> Void

final class GenerationOptionsViewModel<Route: Routable>: ViewModel<Route> {
    struct Input {
        let updateOption: Signal<OptionsMutation>
    }

    struct Output {
        let options: Driver<RuntimeObjectInterface.GenerationOptions>
    }

    func transform(_ input: Input) -> Output {
        input.updateOption
            .emitOnNext { [weak self] mutation in
                guard let self else { return }
                var currentOptions = appDefaults.options
                mutation(&currentOptions)
                appDefaults.options = currentOptions
            }
            .disposed(by: rx.disposeBag)

        return Output(
            options: appDefaults.$options.asDriverOnErrorJustComplete()
        )
    }
}
