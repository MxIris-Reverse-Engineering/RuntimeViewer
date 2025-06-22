import Foundation
import RuntimeViewerArchitectures

open class ViewModel<Route: Routable>: NSObject, ViewModelProtocol {
    public let appServices: AppServices

    public let errorRelay = PublishRelay<Error>()

    public var commonLoading: Driver<Bool> { _commonLoading.asDriver() }

    package let _commonLoading = ActivityIndicator()

    public unowned let router: any Router<Route>

    public init(appServices: AppServices, router: any Router<Route>) {
        self.appServices = appServices
        self.router = router
    }
}
