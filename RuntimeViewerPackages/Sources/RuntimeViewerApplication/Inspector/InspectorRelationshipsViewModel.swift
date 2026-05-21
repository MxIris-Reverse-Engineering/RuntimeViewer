import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

@Loggable(.private)
public final class InspectorRelationshipsViewModel: ViewModel<InspectorRuntimeObjectRoute> {
    public let runtimeObject: RuntimeObject

    @Observed
    public private(set) var rows: [InspectorRelationshipsCellViewModel] = []

    @Observed
    public private(set) var sectionTitle: String = ""

    @Observed
    public private(set) var isEmpty: Bool = false

    @Observed
    public private(set) var emptyMessage: String = ""

    @MemberwiseInit(.public)
    public struct Input {
        public let selectRelationshipClicked: Signal<InspectorRelationshipsCellViewModel>
    }

    public struct Output {
        public let rows: Driver<[InspectorRelationshipsCellViewModel]>
        public let sectionTitle: Driver<String>
        public let isEmpty: Driver<Bool>
        public let emptyMessage: Driver<String>
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRuntimeObjectRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)
        sectionTitle = Self.sectionTitle(for: runtimeObject.kind)
        load()
    }

    public func transform(_ input: Input) -> Output {
        input.selectRelationshipClicked.emitOnNext { [weak self] cellViewModel in
            guard let self else { return }
            documentState.selectionStack.append(cellViewModel.runtimeObject)
        }
        .disposed(by: rx.disposeBag)

        return Output(
            rows: $rows.asDriver(),
            sectionTitle: $sectionTitle.asDriver(),
            isEmpty: $isEmpty.asDriver(),
            emptyMessage: $emptyMessage.asDriver()
        )
    }

    private func load() {
        let target = runtimeObject
        let kind = target.kind
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await documentState.runtimeEngine.relationships(for: target)
                let payload: [RuntimeObject]
                switch kind {
                case .objc(.type(.class)),
                     .swift(.type(.class)):
                    payload = result.subclasses
                case .objc(.type(.protocol)),
                     .swift(.type(.protocol)):
                    payload = result.conformingTypes
                default:
                    payload = []
                }
                await MainActor.run {
                    self.rows = payload.map(InspectorRelationshipsCellViewModel.init)
                    self.isEmpty = payload.isEmpty
                    self.emptyMessage = self.isEmpty
                        ? "No \(self.sectionTitle.lowercased()) found in indexed images."
                        : ""
                }
            } catch {
                await MainActor.run { self.errorRelay.accept(error) }
            }
        }
    }

    private static func sectionTitle(for kind: RuntimeObjectKind) -> String {
        switch kind {
        case .objc(.type(.class)),
             .swift(.type(.class)):
            return "Subclasses"
        case .objc(.type(.protocol)),
             .swift(.type(.protocol)):
            return "Conforming Types"
        default:
            return ""
        }
    }
}
