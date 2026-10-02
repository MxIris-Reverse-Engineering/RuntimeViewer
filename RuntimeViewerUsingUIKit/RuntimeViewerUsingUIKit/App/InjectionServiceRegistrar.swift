import Foundation
import FoundationToolbox
import RuntimeViewerCore

#if RUNTIME_VIEWER_JAILBROKEN
import RuntimeViewerDeviceInjection
#endif

/// Hands this process's injection implementation to `RuntimeEngine`, in the
/// variant that has one.
///
/// The whole type is behind `RUNTIME_VIEWER_JAILBROKEN`, which only the
/// `RuntimeViewerUsingUIKit-JB` target defines. The file itself is in the
/// synchronized group all three app targets share, so the ordinary builds
/// compile it to nothing — they neither link `RuntimeViewerDeviceInjection` nor
/// register anything, and `RuntimeEngine.injectionService` stays `nil`. That is
/// the meaningful state that makes them answer `requiresJailbrokenVariant`
/// rather than a lie about the platform.
@Loggable
enum InjectionServiceRegistrar {
    /// Must run before any engine can be asked about its capabilities, so it
    /// goes first in `didFinishLaunchingWithOptions` — ahead of
    /// `RuntimeEngine.local` and the Bonjour server engine, either of which a
    /// host may query as soon as it is reachable.
    static func registerIfAvailable() {
        #if RUNTIME_VIEWER_JAILBROKEN
        guard let payloadURL = payloadURL() else {
            // Registered anyway: the service reports a missing payload as its
            // own distinct reason, and that is more useful to a user than this
            // build pretending to be the ordinary variant.
            #log(.error, "Jailbroken variant found no embedded payload; injection will report it as unavailable")
            RuntimeEngine.injectionService = RuntimeDeviceInjectionService(
                payloadURL: URL(fileURLWithPath: "/nonexistent/RuntimeViewerServer"),
            )
            return
        }
        #log(.info, "Registering device injection service with payload at \(payloadURL.path, privacy: .public)")
        RuntimeEngine.injectionService = RuntimeDeviceInjectionService(payloadURL: payloadURL)
        #endif
    }

    #if RUNTIME_VIEWER_JAILBROKEN
    /// The embedded `RuntimeViewerServer` binary — the dylib that turns an
    /// injected process into an engine of its own.
    ///
    /// Looked up inside the framework rather than taken as a bare resource:
    /// what gets injected is the Mach-O, not the `.framework` wrapper around
    /// it, and `dlopen` of the directory would fail.
    private static func payloadURL() -> URL? {
        guard let frameworkURL = Bundle.main.url(forResource: "RuntimeViewerServer", withExtension: "framework") else {
            return nil
        }
        let binaryURL = frameworkURL.appendingPathComponent("RuntimeViewerServer")
        return FileManager.default.fileExists(atPath: binaryURL.path) ? binaryURL : nil
    }
    #endif
}
