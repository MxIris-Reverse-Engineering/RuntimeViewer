#if os(macOS)

import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore

public typealias GenerationOptionKeyPath = WritableKeyPath<RuntimeObjectInterface.GenerationOptions, Bool>
public typealias GenerationOptionsMutation = (inout RuntimeObjectInterface.GenerationOptions) -> Void

public final class GenerationOptionsViewModel<Route: Routable>: ViewModel<Route> {
    public struct Input {
        public let updateOption: Signal<GenerationOptionsMutation>

        public init(updateOption: Signal<GenerationOptionsMutation>) {
            self.updateOption = updateOption
        }
    }

    public struct Output {
        public let options: Driver<RuntimeObjectInterface.GenerationOptions>
    }

    public func transform(_ input: Input) -> Output {
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

#endif
