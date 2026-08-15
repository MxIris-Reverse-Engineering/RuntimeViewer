import Foundation
import ObjCIndexing

extension ObjCIndexingEvent.Phase {
    /// The RuntimeViewer loading phase this indexing phase maps onto.
    ///
    /// The library names its phases without the `ObjC` qualifier — it only
    /// ever indexes Objective-C — while `RuntimeObjectsLoadingProgress.Phase`
    /// spans both the ObjC and Swift halves of a load, so it keeps the
    /// qualifier to stay unambiguous.
    var loadingPhase: RuntimeObjectsLoadingProgress.Phase {
        switch self {
        case .indexingSubclasses: .indexingObjCSubclasses
        case .loadingClasses: .loadingObjCClasses
        case .loadingProtocols: .loadingObjCProtocols
        case .indexingConformances: .indexingObjCConformances
        case .loadingCategories: .loadingObjCCategories
        }
    }
}
