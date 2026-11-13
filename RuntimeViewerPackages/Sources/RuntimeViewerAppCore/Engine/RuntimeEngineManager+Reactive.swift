#if os(macOS)
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerEngineManagement

// The Rx face of `RuntimeEngineManager`, kept out of the manager's own module
// so a headless process does not link RxSwift. Both modules live in one
// package, which is why the conformance below needs no `@retroactive`.

@MainActor
extension RuntimeEngineManager: ReactiveCompatible {}

@MainActor
extension Reactive where Base == RuntimeEngineManager {
    public var runtimeEngines: Driver<[RuntimeEngine]> {
        Driver.combineLatest(
            base.$systemRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []),
            base.$attachedRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []),
            base.$bonjourRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []),
            base.$mirroredEngines.asObservable().asDriver(onErrorJustReturn: [:]),
            resultSelector: { $0 + $1 + $2 + $3.values.elements }
        )
    }

    public var runtimeEngineSections: Driver<[RuntimeEngineSection]> {
        base.$runtimeEngineSections.asObservable().asDriver(onErrorJustReturn: [])
    }
}
#endif
