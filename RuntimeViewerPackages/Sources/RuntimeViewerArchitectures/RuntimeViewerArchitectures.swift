@_exported import RxSwift
@_exported import RxCocoa

// @_exported import RxSwiftExt
@_exported import RxSwiftPlus
@_exported import RxCombine
@_exported import RxDefaultsPlus
@_exported import RxEnumKit
@_exported import EnumKit
@_exported import RxConcurrency

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@_exported import RxAppKit
@_exported import CocoaCoordinator
@_exported import RxCocoaCoordinator
#if USING_SYSTEM_UXKIT
@_exported import UXKitCoordinator
#else
@_exported import OpenUXKitCoordinator
#endif
#endif

#if canImport(UIKit) && !os(macOS)
@_exported import RxUIKit
@_exported import XCoordinator
@_exported import XCoordinatorRx

public typealias Routable = Route
#endif


@_exported import Dependencies

public extension ObservableType {
    func observeOnMainScheduler() -> Observable<Element> {
        observe(on: MainScheduler.instance)
    }
}
