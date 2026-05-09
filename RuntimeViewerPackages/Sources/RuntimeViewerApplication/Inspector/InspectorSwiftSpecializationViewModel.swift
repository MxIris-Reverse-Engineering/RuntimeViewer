import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

@Loggable(.private)
public final class InspectorSwiftSpecializationViewModel: ViewModel<InspectorRuntimeObjectRoute> {
    @Observed
    private var runtimeObject: RuntimeObject

    public var runtimeObjectDisplayName: String { runtimeObject.displayName }

    @MemberwiseInit(.public)
    public struct Input {
        public let addSpecializationClicked: Signal<Void>
        public let selectSpecializationClicked: Signal<RuntimeObject>
    }

    public struct Output {
        public let specializedChildren: Driver<[RuntimeObject]>
    }

    public func transform(_ input: Input) -> Output {
        input.addSpecializationClicked.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.requestSpecializationSheet(runtimeObject))
        }
        .disposed(by: rx.disposeBag)

        input.selectSpecializationClicked.emitOnNext { [weak self] specialized in
            guard let self else { return }
            router.trigger(.selectRuntimeObject(specialized))
        }
        .disposed(by: rx.disposeBag)

        let specializedChildren = $runtimeObject
            .map { runtimeObject in
                runtimeObject.children.filter { $0.properties.contains(.isSpecialized) }
            }
            .asDriverOnErrorJustComplete()

        return Output(specializedChildren: specializedChildren)
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRuntimeObjectRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)
    }
}
