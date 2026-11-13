#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RxSwift
import RxCocoa
import RuntimeViewerUI

public protocol RuntimeObjectCellDisplayable: AnyObject {
    var appearanceDriver: Driver<RuntimeObjectCellAppearance> { get }
}

#endif
