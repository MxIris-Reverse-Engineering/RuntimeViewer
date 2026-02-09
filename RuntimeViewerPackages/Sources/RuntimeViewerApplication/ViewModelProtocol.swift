import RuntimeViewerArchitectures

public protocol ViewModelProtocol<Route>: AnyObject {
    associatedtype Route: Routable
    var documentState: DocumentState { get }
    var commonLoading: Driver<Bool> { get }
    var delayedLoading: Driver<Bool> { get }
    var errorRelay: PublishRelay<Error> { get }
}
