import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class InspectorRuntimeNodeViewModel: ViewModel<InspectorRoute> {
    @RxObserved
    var runtimeNode: RuntimeImageNode

    init(runtimeNode: RuntimeImageNode, documentState: DocumentState, router: any Router<InspectorRoute>) {
        self.runtimeNode = runtimeNode
        super.init(documentState: documentState, router: router)
    }
}
