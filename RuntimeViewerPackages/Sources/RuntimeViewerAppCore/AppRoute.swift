#if os(macOS)

import Dependencies
import RuntimeViewerArchitectures

/// The app's own windows, which a view model asks for through `appRouter`.
public enum AppRoute: Routable {
    case settings
}

/// The router that opens the app's own windows. Its live value, the app's coordinator, lives in
/// RuntimeViewerAppUI, which adds the `DependencyKey` conformance; this module declares the interface
/// and the value tests get (swift-dependencies' "Separating interface and implementation").
package enum AppRouterKey: TestDependencyKey {
    package static var testValue: any Router<AppRoute> & Sendable {
        MainActor.assumeIsolated { UnimplementedRouter<AppRoute>() }
    }
}

@MainActor
extension DependencyValues {
    // `& Sendable` is load-bearing: `Router` is `@MainActor`, but an existential
    // does not pick up `Sendable` from that, and a dependency value has to be
    // `Sendable` to cross into `DependencyValues`.
    public var appRouter: any Router<AppRoute> & Sendable {
        get { self[AppRouterKey.self] }
        set { self[AppRouterKey.self] = newValue }
    }
}

/// The router a test gets when it did not say which one it expects: triggering a route records an
/// issue instead of opening a window.
@MainActor
package final class UnimplementedRouter<Route: Routable>: Router {
    package init() {}

    package func contextTrigger(_ route: Route, with options: TransitionOptions, completion: ContextPresentationHandler?) {
        reportIssue("An unimplemented router was asked for \(route); override the dependency in the test.")
    }
}

#endif
