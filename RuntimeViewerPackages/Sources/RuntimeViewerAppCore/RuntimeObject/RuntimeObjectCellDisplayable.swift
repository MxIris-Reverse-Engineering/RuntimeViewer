#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import RxSwift
import RxCocoa

public protocol RuntimeObjectCellDisplayable: AnyObject {
    var appearanceDriver: Driver<RuntimeObjectCellAppearance> { get }
}

#endif
