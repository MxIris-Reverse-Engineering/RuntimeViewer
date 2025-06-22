#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerCore
import RuntimeViewerArchitectures

public class InspectorPlaceholderViewModel: ViewModel<InspectorRoute> {}
public class InspectorRuntimeObjectViewModel: ViewModel<InspectorRoute> {
    @Observed
    var runtimeObject: RuntimeObjectType

    @Observed
    var runtimeObjectHierarchy: [String] = []

    public struct Input {}

    public struct Output {}

    public func transform(_ input: Input) -> Output {
        Output()
    }

    init(runtimeObject: RuntimeObjectType, appServices: AppServices, router: any Router<InspectorRoute>) {
        self.runtimeObject = runtimeObject
        super.init(appServices: appServices, router: router)
//        $runtimeObject.flatMap { appServices.runtimeEngine. }
    }
}

public class InspectorRuntimeNodeViewModel: ViewModel<InspectorRoute> {
    @Observed
    var runtimeNode: RuntimeNamedNode

    init(runtimeNode: RuntimeNamedNode, appServices: AppServices, router: any Router<InspectorRoute>) {
        self.runtimeNode = runtimeNode
        super.init(appServices: appServices, router: router)
    }
}
