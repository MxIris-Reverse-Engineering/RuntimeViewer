import RuntimeViewerArchitectures

public protocol ViewModelProtocol<Route>: AnyObject {
    associatedtype Route: Routable
    var appServices: AppServices { get }
    var commonLoading: Driver<Bool> { get }
    var errorRelay: PublishRelay<Error> { get }
}
