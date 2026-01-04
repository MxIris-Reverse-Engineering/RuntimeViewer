import Foundation
import FoundationToolbox
import RuntimeViewerArchitectures

open class ViewModel<Route: Routable>: NSObject, ViewModelProtocol, Loggable {
    public let appServices: AppServices

    public let errorRelay = PublishRelay<Error>()

    public var commonLoading: Driver<Bool> { _commonLoading.asDriver() }

    public var delayedLoading: Driver<Bool> {
        _commonLoading
            .distinctUntilChanged()
            .flatMapLatest { isLoading -> Driver<Bool> in
                if isLoading {
                    // If loading starts, return a sequence that emits 'true' after a delay.
                    // If 'isLoading' becomes false before the delay finishes,
                    // flatMapLatest will dispose this subscription, cancelling the 'true' emission.
                    return Driver.just(true)
                        .delay(.milliseconds(500))
                } else {
                    // If loading ends, emit 'false' immediately to hide the spinner.
                    return Driver.just(false)
                }
            }
    }

    
    package let _commonLoading = ActivityIndicator()

    public unowned let router: any Router<Route>

    @Dependency(\.appDefaults)
    public var appDefaults

    public init(appServices: AppServices, router: any Router<Route>) {
        self.appServices = appServices
        self.router = router
    }
}
