import AppKit
import Combine
import OSLog
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerCatalystExtensions
import RuntimeViewerInjection
import RuntimeViewerCrossReferences

extension NSObject {
    @objc func rvch_makeKeyAndOrderFront(_ sender: Any?) {}
}

/// What the four shells run: the Mac Catalyst helper application and the
/// Mac Catalyst, local and offline XPC services. Each shell only loads this
/// plugin and calls its entry point, so the app ships one copy of
/// RuntimeViewerCore for all four processes instead of one per executable.
@objc(ServicePluginEntry)
final class ServicePluginEntry: NSObject, ServicePlugin {
    private static let logger = Logger(subsystem: "com.RuntimeViewer.RuntimeViewerServicePlugin", category: "ServicePluginEntry")

    var observation: NSKeyValueObservation?

    var runtimeEngine: RuntimeEngine?

    private var engineStateSubscription: AnyCancellable?

    /// What an XPC service serves its in-process engine through; kept for the
    /// life of the process.
    private var serviceHost: RuntimeLocalServiceHost?

    /// What the offline service serves its file through; kept for the life of
    /// the process.
    private var offlineServiceHost: RuntimeOfflineServiceHost?

    override required init() {
        super.init()
        // Every process that loads this plugin picks the variant-specific
        // helper-daemon identity here (see `RuntimeViewerMachServiceName`), the
        // way the app, the daemon and the injected server flip this flag under
        // the same condition. The helper application is the one that depends
        // on it: a helper that does not flip it registers with a different
        // daemon than the app that launched it, never finds the app's endpoint,
        // and the app's Catalyst engine loads forever.
        #if RUNTIMEVIEWER_ARM64E
        runtimeViewerIsARM64EVariant = true
        #endif
    }

    @objc func setupWindow(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let uinsWindowClass = NSClassFromString("UINSWindow"), window.isKind(of: uinsWindowClass) {
            window.setFrame(.zero, display: true)
        }
    }

    func launchCatalystHelper() {
        hideApplication()

        // Before the engine is built, because the injection commands are
        // installed as its connection is set up. The helper cannot inject
        // anything — the Mac injects through the privileged helper daemon, and
        // the processes a Catalyst engine could attach to are this Mac's, which
        // the app enumerates itself — but it still has to carry the capability
        // query, or the app cannot tell this helper apart from one built before
        // these commands existed.
        RuntimeInjection.install()
        RuntimeCrossReferences.install()

        let runtimeEngine = RuntimeEngine(source: .macCatalystServer)
        self.runtimeEngine = runtimeEngine
        observeEngineState(of: runtimeEngine)
        Task {
            do {
                try await runtimeEngine.connect()
            } catch {
                // A helper that could not reach its app has nothing to do, and
                // staying alive is harmful: the daemon opens the helper with
                // `createsNewApplicationInstance = false`, so a lingering
                // instance is what the app's next launch request gets back,
                // and that instance never handshakes again.
                Self.logger.error("Mac Catalyst helper could not connect to the app: \(error, privacy: .public); exiting")
                Self.terminate()
            }
        }
    }

    func runCatalystService() {
        // Before the engine is built, for the reason given in `launchCatalystHelper()`.
        RuntimeInjection.install()
        RuntimeCrossReferences.install()
        // The service keeps derived data for the Mac Catalyst engine, as the
        // local service does for "My Mac"; the helper application, which
        // serves the standalone command-line host, does not.
        RuntimeDerivedData.enableInThisProcess()

        // Nothing in the service is a UIKit application, so it starts without
        // UIKit and the hundreds of images behind it, and its image list would
        // come out shorter than the helper application's. Loading UIKit once,
        // before the engine takes its first look, starts the service where the
        // helper application starts.
        if dlopen("/System/Library/Frameworks/UIKit.framework/UIKit", RTLD_NOW) == nil {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            Self.logger.error("Mac Catalyst service could not load UIKit: \(reason, privacy: .public)")
        }

        // The same job as the local service, so the same host. The app's
        // client engine is `.macCatalystClient`; which process answers it is
        // the transport's business.
        serveInProcessEngine(engineID: "catalyst-runtime-service.\(ProcessInfo.processInfo.processIdentifier)", serviceName: "Mac Catalyst service")
    }

    func runLocalService() {
        // Before the engine exists, because the injection commands are
        // installed as a connection is set up and there is no path that adds
        // them afterwards. This service cannot inject anything itself — the Mac
        // injects through the privileged helper daemon — but it still has to
        // answer the capability query, or a host cannot tell it apart from a
        // build that predates these commands. The cross-reference commands, for
        // the same reason: a callers query scans the images mapped into this
        // process, which is where the app's "My Mac" engine runs.
        RuntimeInjection.install()
        RuntimeCrossReferences.install()
        // Derived data — the Find corpora of the shared cache's images, kept on
        // disk under the app's caches — is read and written only by the
        // processes that serve the app's engines, so it is turned on here,
        // before the engine exists.
        RuntimeDerivedData.enableInThisProcess()

        serveInProcessEngine(engineID: "local-service.\(ProcessInfo.processInfo.processIdentifier)", serviceName: "Local service")
    }

    func runOfflineService() {
        // The plugin links both command modules, so the offline service
        // installs them like every other process that serves an engine. Nothing
        // ever asks it for either: an engine reading a file answers the
        // injection capability query and every cross-reference command itself,
        // since a file has no processes to inject into and its images are never
        // mapped into this process for the scan to read.
        RuntimeInjection.install()
        RuntimeCrossReferences.install()

        let listener: RuntimeXPCServiceListenerConnection
        do {
            listener = try RuntimeXPCServiceListenerConnection.embeddedService()
        } catch {
            // Without a listener there is no service; let launchd see a clean failure.
            Self.logger.error("Offline service could not create its listener: \(error, privacy: .public)")
            exit(EXIT_FAILURE)
        }

        // Derived data — the Find corpora of the cache images this instance
        // reads — kept under the identity of the dyld shared cache they come
        // from, not this Mac's; see `RuntimeDerivedData.offlineStore(for:isSharedCacheImage:)`.
        RuntimeDerivedData.enableForOfflineEngineInThisProcess()

        // The service declares `_MultipleInstances`, and the app starts an
        // instance for every file it opens: the connection's first hello names
        // the file, and the host reads it and serves it before answering.
        let offlineServiceHost = RuntimeOfflineServiceHost(connection: listener)
        self.offlineServiceHost = offlineServiceHost

        // Nobody else can ever reach this instance — launchd starts a new one
        // for every connection — so once its client closed the connection,
        // exiting is the only way the parsed file's memory is given back.
        listener.setClientDepartureHandler {
            exit(EXIT_SUCCESS)
        }

        // `xpc_main`; never returns. Nothing is read until the first hello
        // names the file, so there is nothing to set up first.
        offlineServiceHost.activate()
    }

    /// Serves an in-process engine on this XPC service's listener, as the
    /// local and the Mac Catalyst services both do. Never returns.
    private func serveInProcessEngine(engineID: String, serviceName: String) -> Never {
        let runtimeEngine = RuntimeEngine(source: .local, engineID: engineID)
        self.runtimeEngine = runtimeEngine
        let serviceHost: RuntimeLocalServiceHost
        do {
            serviceHost = RuntimeLocalServiceHost(engine: runtimeEngine, connection: try RuntimeXPCServiceListenerConnection.embeddedService())
        } catch {
            // Without a listener there is no service; let launchd see a clean failure.
            Self.logger.error("\(serviceName, privacy: .public) could not create its listener: \(error, privacy: .public)")
            exit(EXIT_FAILURE)
        }
        self.serviceHost = serviceHost

        // Every handler has to be in place before the listener activates —
        // SwiftyXPC copies them onto a connection at accept time — and
        // `activate()` is `xpc_main`, which parks the main thread for good. So
        // the asynchronous set-up runs off the main thread while the main
        // thread waits for it, rather than `await`ing and then calling
        // `xpc_main` from inside a block the main queue is still executing.
        let setupFinished = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                try await serviceHost.start()
            } catch {
                Self.logger.error("\(serviceName, privacy: .public) could not start its runtime engine: \(error, privacy: .public)")
                exit(EXIT_FAILURE)
            }
            setupFinished.signal()
        }
        setupFinished.wait()

        serviceHost.activate()
        // `activate()` is `xpc_main` and does not return; nothing below runs.
        exit(EXIT_FAILURE)
    }

    /// Keeps the helper application out of sight. As a UIKit application it
    /// would show a window and a Dock icon; it is a background process. Only
    /// the helper application needs this — the XPC services have no
    /// application to hide.
    private func hideApplication() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let windowClass = objc_getClass("UINSWindow") as? AnyClass {
            let originalMethod = class_getInstanceMethod(windowClass, #selector(NSWindow.makeKeyAndOrderFront(_:)))
            let replacementMethod = class_getInstanceMethod(windowClass, #selector(NSObject.rvch_makeKeyAndOrderFront(_:)))
            if let originalMethod, let replacementMethod {
                method_exchangeImplementations(originalMethod, replacementMethod)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(setupWindow(_:)), name: Notification.Name("_NSWindowWillBecomeVisible"), object: nil)
    }

    /// Exits once the app side goes away. The daemon terminates the helper
    /// when the caller that launched it exits, but that bookkeeping lives in
    /// the daemon's memory and is lost when the daemon is reinstalled while
    /// the app runs; the helper has to look after itself as well.
    ///
    /// Registration in the injected-endpoint registry is deliberately off for
    /// the helper (`RuntimeXPCMachServiceServerConnection.shouldAnnounceListenerEndpoint`),
    /// so unlike an injected server nothing ever reconnects to it: a
    /// disconnected helper is a dead helper.
    private func observeEngineState(of runtimeEngine: RuntimeEngine) {
        engineStateSubscription = runtimeEngine.statePublisher
            .sink { state in
                guard case .disconnected(let error) = state else { return }
                if let error {
                    Self.logger.error("Mac Catalyst helper lost its app connection: \(error, privacy: .public); exiting")
                } else {
                    Self.logger.info("Mac Catalyst helper connection closed; exiting")
                }
                Self.terminate()
            }
    }

    private static func terminate() {
        DispatchQueue.main.async {
            exit(EXIT_FAILURE)
        }
    }
}
