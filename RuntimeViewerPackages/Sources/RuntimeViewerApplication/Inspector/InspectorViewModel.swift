#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class InspectorPlaceholderViewModel: ViewModel<InspectorRoute> {}
//public class InspectorRuntimeObjectViewModel: ViewModel<InspectorRoute> {
//    @Observed
//    var runtimeObject: RuntimeObjCRuntimeObject
//
//    @Observed
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

public final class InspectorRuntimeNodeViewModel: ViewModel<InspectorRoute> {
    @Observed
    var runtimeNode: RuntimeImageNode

    init(runtimeNode: RuntimeImageNode, documentState: DocumentState, router: any Router<InspectorRoute>) {
        self.runtimeNode = runtimeNode
        super.init(documentState: documentState, router: router)
    }
}
