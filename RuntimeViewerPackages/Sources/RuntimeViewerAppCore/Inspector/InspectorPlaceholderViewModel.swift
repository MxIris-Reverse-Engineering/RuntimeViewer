import RuntimeViewerArchitectures

public final class InspectorPlaceholderViewModel: ViewModel<InspectorRoute> {}
//public class InspectorRuntimeObjectViewModel: ViewModel<InspectorRoute> {
//    @RxObserved
//    var runtimeObject: RuntimeObjCRuntimeObject
//
//    @RxObserved
//    var runtimeObjectHierarchy: [String] = []
//
//    public struct Input {}
//
//    public struct Output {}
//
//    public func transform(_ input: Input) -> Output {
//        Output()
//    }
//
//    init(runtimeObject: RuntimeObjCRuntimeObject, documentState: DocumentState, router: any Router<InspectorRoute>) {
//        self.runtimeObject = runtimeObject
//        super.init(documentState: documentState, router: router)
////        $runtimeObject.flatMap { appState.runtimeEngine. }
//    }
//}
