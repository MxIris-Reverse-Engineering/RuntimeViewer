import RuntimeViewerArchitectures

/// Test double for `Router`. Records every triggered route so tests can
/// assert on navigation side effects without spinning up a real
/// coordinator hierarchy. The completion handler is invoked immediately
/// with an empty transition context, mirroring an instantaneous
/// transition.
///
/// `ViewModel` holds its router `unowned`, so tests MUST keep the
/// `MockRouter` alive for the whole lifetime of the view model under
/// test (a stored `let` in the test body is enough).
@MainActor
package final class MockRouter<Route: Routable>: Router {
    private struct EmptyTransitionContext: TransitionContext {
        let presentables: [any Presentable] = []
    }

    package private(set) var triggeredRoutes: [Route] = []

    package init() {}

    package func contextTrigger(_ route: Route, with options: TransitionOptions, completion: ContextPresentationHandler?) {
        triggeredRoutes.append(route)
        completion?(EmptyTransitionContext())
    }
}
