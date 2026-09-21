import AppKit
import Combine
import OSLog
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerCatalystExtensions

extension NSObject {
    @objc func rvch_makeKeyAndOrderFront(_ sender: Any?) {}
}

@objc(AppKitPluginImpl)
final class AppKitPluginImpl: NSObject, AppKitPlugin {
    private static let logger = Logger(subsystem: "com.RuntimeViewer.RuntimeViewerCatalystHelper", category: "AppKitPluginImpl")

    var observation: NSKeyValueObservation?

    var runtimeEngine: RuntimeEngine?

    private var engineStateSubscription: AnyCancellable?

    override required init() {
        super.init()
        // The helper is the fourth executable entry point that has to pick the
        // variant-specific helper-daemon identity (see `RuntimeViewerMachServiceName`).
        // The app, the daemon and the injected server each flip this flag under
        // the same condition; a helper that does not flip it registers with a
        // different daemon than the app that launched it, never finds the app's
        // endpoint, and the app's Catalyst engine loads forever.
        #if RUNTIMEVIEWER_ARM64E
        runtimeViewerIsARM64EVariant = true
        #endif
        NSApplication.shared.setActivationPolicy(.prohibited)
        if let UINSWindow = objc_getClass("UINSWindow") as? AnyClass {
            let m1 = class_getInstanceMethod(UINSWindow, #selector(NSWindow.makeKeyAndOrderFront(_:)))
            let m2 = class_getInstanceMethod(UINSWindow, #selector(NSObject.rvch_makeKeyAndOrderFront(_:)))
            if let m1, let m2 {
                method_exchangeImplementations(m1, m2)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(setupWindow(_:)), name: Notification.Name("_NSWindowWillBecomeVisible"), object: nil)
    }

    @objc func setupWindow(_ notification: Notification) {
        if let window = notification.object as? NSWindow, let uinsWindowClass = NSClassFromString("UINSWindow"), window.isKind(of: uinsWindowClass) {
            window.setFrame(.zero, display: true)
        }
    }

    func launch() {
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
