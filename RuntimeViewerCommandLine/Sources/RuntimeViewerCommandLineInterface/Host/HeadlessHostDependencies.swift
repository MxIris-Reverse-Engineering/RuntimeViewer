#if os(macOS)
import Combine
import Dependencies
import Foundation
import RuntimeViewerCore
import RuntimeViewerEngineManagement
import RuntimeViewerHelperClient

/// What a standalone host installs before it starts serving: a
/// `RuntimeEngineManager` in its headless configuration and the resource
/// locator that says where RuntimeViewer.app is.
///
/// `prepareDependencies` is process-wide and must run before anything
/// resolves a dependency, which is why this is one call made once from
/// `host run`. The app never goes through here: it already owns a manager in
/// the `.application` configuration and its bundle is `Bundle.main`.
@MainActor
public enum HeadlessHostDependencies {
    private static var eventSubscription: AnyCancellable?

    /// Installs the dependencies and returns the resolver the executor serves.
    public static func install(applicationBundle: ApplicationBundleLocator.Resolution?) -> EngineManagerSourceResolver {
        if let applicationBundle {
            HostLog.write("Application bundle: \(applicationBundle.bundleURL.path) (from \(applicationBundle.step.rawValue))")
        } else {
            HostLog.write("No RuntimeViewer.app found; attach and the Catalyst runtime are unavailable (pass --app-bundle or set \(ApplicationBundleLocator.environmentVariable))")
        }
        let resourceLocator = ApplicationBundleLocator.makeResourceLocator(for: applicationBundle)
        let engineManager = RuntimeEngineManager(configuration: .headlessHost)
        prepareDependencies { dependencies in
            dependencies.runtimeResourceLocator = resourceLocator
            dependencies.runtimeEngineManager = engineManager
        }
        // A standalone host has no notification service; the events go to
        // host.log so a puzzling `sources` output can be explained after the fact.
        eventSubscription = engineManager.eventPublisher.sink { event in
            switch event {
            case .engineConnected(let engine):
                HostLog.write("Engine connected: \(engine.source.description) [\(engine.engineID)]")
            case .hostDisconnected(let source, let error):
                HostLog.write("Host disconnected: \(source.description)" + (error.map { " (\($0.localizedDescription))" } ?? ""))
            case .catalystHelperUnavailable(let error):
                HostLog.write("Mac Catalyst runtime unavailable: \(error.localizedDescription)")
            }
        }

        @Dependency(\.runtimeInjectClient) var injectClient
        @Dependency(\.helperServiceManager) var helperServiceManager
        return EngineManagerSourceResolver.forEngineManager(
            engineManager,
            injectClient: injectClient,
            helperServiceManager: helperServiceManager,
            applicationBundleURL: applicationBundle?.bundleURL
        )
    }
}
#endif
