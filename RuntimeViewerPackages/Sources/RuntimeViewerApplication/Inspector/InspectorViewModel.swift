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
//    init(runtimeObject: RuntimeObjCRuntimeObject, appServices: AppServices, router: any Router<InspectorRoute>) {
//        self.runtimeObject = runtimeObject
//        super.init(appServices: appServices, router: router)
////        $runtimeObject.flatMap { appServices.runtimeEngine. }
//    }
//}

public final class InspectorRuntimeNodeViewModel: ViewModel<InspectorRoute> {
    @Observed
    var runtimeNode: RuntimeImageNode

    init(runtimeNode: RuntimeImageNode, appServices: AppServices, router: any Router<InspectorRoute>) {
        self.runtimeNode = runtimeNode
        super.init(appServices: appServices, router: router)
    }
}
