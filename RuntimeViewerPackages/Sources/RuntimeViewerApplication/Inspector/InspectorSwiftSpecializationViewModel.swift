import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

@Loggable(.private)
public final class InspectorSwiftSpecializationViewModel: ViewModel<InspectorRuntimeObjectRoute> {
    @RxObserved
    private var runtimeObject: RuntimeObject

    public var runtimeObjectDisplayName: String { runtimeObject.displayName }

    @MemberwiseInit(.public)
    public struct Input {
        public let addSpecializationClicked: Signal<Void>
        public let selectSpecializationClicked: Signal<InspectorSwiftSpecializationCellViewModel>
    }

    public struct Output {
        public let specializedChildren: Driver<[InspectorSwiftSpecializationCellViewModel]>
    }

    public func transform(_ input: Input) -> Output {
        input.addSpecializationClicked.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.requestSpecializationSheet(runtimeObject))
        }
        .disposed(by: rx.disposeBag)

        input.selectSpecializationClicked.emitOnNext { [weak self] cellViewModel in
            guard let self else { return }
            documentState.selectionRouter.trigger(.push(cellViewModel.runtimeObject))
        }
        .disposed(by: rx.disposeBag)

        let specializedChildren = $runtimeObject
            .map { runtimeObject in
                runtimeObject.children
                    .filter { $0.properties.contains(.isSpecialized) }
                    .map(InspectorSwiftSpecializationCellViewModel.init)
            }
            .asDriverOnErrorJustComplete()

        return Output(specializedChildren: specializedChildren)
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRuntimeObjectRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)
    }

    /// Point the tab at another object. Unlike the class-hierarchy and
    /// relationships tabs this needs no placeholder: the specialized children
    /// are already in memory on the `RuntimeObject`, so `$runtimeObject` maps
    /// straight to the new rows with no fetch in between.
    public func update(for runtimeObject: RuntimeObject) {
        guard self.runtimeObject != runtimeObject else { return }
        self.runtimeObject = runtimeObject
    }
}
