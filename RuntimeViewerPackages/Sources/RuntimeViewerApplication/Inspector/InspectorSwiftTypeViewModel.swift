import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

@Loggable(.private)
public final class InspectorSwiftTypeViewModel: ViewModel<InspectorRoute> {
    @Observed
    private var runtimeObject: RuntimeObject

    /// Stable display name for the runtime object backing this view model.
    /// Used by the view layer to render the Specialization tab's header
    /// without binding another driver for what is effectively static text.
    public var runtimeObjectDisplayName: String { runtimeObject.displayName }

    public struct SegmentVisibility: Equatable, Sendable {
        public let showsHierarchy: Bool
        public let showsSpecialization: Bool

        public init(showsHierarchy: Bool, showsSpecialization: Bool) {
            self.showsHierarchy = showsHierarchy
            self.showsSpecialization = showsSpecialization
        }
    }

    @MemberwiseInit(.public)
    public struct Input {
        public let addSpecializationClicked: Signal<Void>
        public let selectSpecializationClicked: Signal<RuntimeObject>
    }

    public struct Output {
        public let hierarchy: Driver<String>
        public let specializedChildren: Driver<[RuntimeObject]>
        public let segmentVisibility: Driver<SegmentVisibility>
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

        let hierarchy = $runtimeObject.flatMapLatest { [unowned self] runtimeObject in
            do {
                return try await documentState.runtimeEngine.hierarchy(for: runtimeObject).joined(separator: "\n")
            } catch {
                #log(.error, "Failed to fetch class hierarchy for runtime object: \("\(runtimeObject)", privacy: .public) with error: \(error, privacy: .public)")
                return runtimeObject.displayName
            }
        }
        .catchAndReturn(runtimeObject.displayName)
        .observeOnMainScheduler()
        .asDriverOnErrorJustComplete()

        let specializedChildren = $runtimeObject
            .map { runtimeObject in
                runtimeObject.children.filter { $0.properties.contains(.isSpecialized) }
            }
            .asDriverOnErrorJustComplete()

        let segmentVisibility = $runtimeObject
            .map { runtimeObject -> SegmentVisibility in
                let isClass: Bool
                if case .swift(.type(.class)) = runtimeObject.kind {
                    isClass = true
                } else {
                    isClass = false
                }
                let isGeneric = runtimeObject.properties.contains(.isGeneric)
                let isSpecialized = runtimeObject.properties.contains(.isSpecialized)
                return SegmentVisibility(
                    showsHierarchy: isClass,
                    showsSpecialization: isGeneric && !isSpecialized
                )
            }
            .asDriverOnErrorJustComplete()

        return Output(
            hierarchy: hierarchy,
            specializedChildren: specializedChildren,
            segmentVisibility: segmentVisibility
        )
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)
    }
}
