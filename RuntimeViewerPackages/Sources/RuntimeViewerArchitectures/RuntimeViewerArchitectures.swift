@_exported import RxSwift
@_exported import RxCocoa
//@_exported import RxSwiftExt
@_exported import RxSwiftPlus
@_exported import RxCombine
@_exported import RxDefaultsPlus
@_exported import RxEnumKit
@_exported import EnumKit

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@_exported import RxAppKit
@_exported import CocoaCoordinator
@_exported import RxCocoaCoordinator
@_exported import OpenUXKitCoordinator
//@_exported import UXKitCoordinator
#endif

#if canImport(UIKit)
@_exported import RxUIKit
@_exported import XCoordinator
@_exported import XCoordinatorRx
public typealias Routable = Route
#endif
