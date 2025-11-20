import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import Dependencies
import RuntimeViewerCore

typealias OptionKeyPath = WritableKeyPath<RuntimeObjectInterface.GenerationOptions, Bool>

class GenerationOptionsViewModel<Route: Routable>: ViewModel<Route> {
    struct Input {
        let updateOption: Signal<(OptionKeyPath, Bool)>
    }

    struct Output {
        let options: Driver<RuntimeObjectInterface.GenerationOptions>
    }

    @Dependency(\.appDefaults)
    var appDefaults

    func transform(_ input: Input) -> Output {
        input.updateOption
            .emit(onNext: { [weak self] (keyPath, value) in
                guard let self = self else { return }
                var currentOptions = appDefaults.options
                currentOptions[keyPath: keyPath] = value
                appDefaults.options = currentOptions
            })
            .disposed(by: rx.disposeBag)

        return Output(
            options: appDefaults.$options.asDriverOnErrorJustComplete()
        )
    }
}
