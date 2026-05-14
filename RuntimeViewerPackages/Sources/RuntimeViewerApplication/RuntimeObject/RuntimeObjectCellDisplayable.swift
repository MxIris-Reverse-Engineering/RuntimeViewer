#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RxSwift
import RxCocoa
import RuntimeViewerUI

public protocol RuntimeObjectCellDisplayable: AnyObject {
    var primaryIconDriver: Driver<NSUIImage> { get }
    var secondaryIconDriver: Driver<NSUIImage?> { get }
    var tertiaryIconDriver: Driver<NSUIImage?> { get }
    var titleDriver: Driver<NSAttributedString> { get }
    var subtitleDriver: Driver<NSAttributedString?> { get }
}

extension RuntimeObjectCellDisplayable {
    public var subtitleDriver: Driver<NSAttributedString?> {
        .just(nil)
    }
}

#endif
