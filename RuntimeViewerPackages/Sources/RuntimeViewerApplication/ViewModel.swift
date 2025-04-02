import Foundation
import RuntimeViewerArchitectures

open class ViewModel<Route: Routable>: NSObject {
    public let appServices: AppServices

    public let errorRelay = PublishRelay<Error>()

    public unowned let router: any Router<Route>
    
    public init(appServices: AppServices, router: any Router<Route>) {
        self.appServices = appServices
        self.router = router
    }
}
