#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RxSwift
import RxCocoa

public protocol RuntimeObjectCellDisplayable: AnyObject {
    var appearanceDriver: Driver<RuntimeObjectCellAppearance> { get }
}

#endif
