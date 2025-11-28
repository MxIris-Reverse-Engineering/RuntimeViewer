import RuntimeViewerCore
import RuntimeViewerArchitectures

extension RuntimeEngineManager: ReactiveCompatible {}

extension Reactive where Base == RuntimeEngineManager {
    public var runtimeEngines: Driver<[RuntimeEngine]> {
        Driver.combineLatest(base.$systemRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []), base.$attachedRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []), base.$bonjourRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []), resultSelector: { $0 + $1 + $2 })
    }
}
