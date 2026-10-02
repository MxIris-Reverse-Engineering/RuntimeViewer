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
        guard let frameworksURL = Bundle.main.privateFrameworksURL,
              let payloadURL = payloadURL(inFrameworksAt: frameworksURL)
        else {
            // Registered anyway: the service reports a missing payload as its
            // own distinct reason, and that is more useful to a user than this
            // build pretending to be the ordinary variant.
            #log(.error, "Jailbroken variant found no embedded payload; injection will report it as unavailable")
            RuntimeEngine.injectionService = RuntimeDeviceInjectionService(
                payloadURL: URL(fileURLWithPath: "/nonexistent/RuntimeViewerServer"),
                dependencyDirectoryURL: URL(fileURLWithPath: "/nonexistent", isDirectory: true),
            )
            return
        }
        #log(.info, "Registering device injection service with payload at \(payloadURL.path, privacy: .public)")
        // The same directory serves as the dependency source: the payload
        // loads `@rpath/libswiftCompatibilitySpan.dylib`, which Xcode embeds
        // right beside it, and the staged copy has to carry it along.
        RuntimeEngine.injectionService = RuntimeDeviceInjectionService(
            payloadURL: payloadURL,
            dependencyDirectoryURL: frameworksURL,
        )
        #endif
    }

    #if RUNTIME_VIEWER_JAILBROKEN
    /// The embedded `RuntimeViewerServer` binary — the dylib that turns an
    /// injected process into an engine of its own.
    ///
    /// Reached through `privateFrameworksURL`, not
    /// `url(forResource:withExtension:)`: the `Embed RuntimeViewerMobileServer
    /// Framework` phase puts the payload in the bundle's `Frameworks`
    /// directory, and the resource lookup searches the resource directory —
    /// the bundle root on iOS — so it would never see it. The macOS app does
    /// use the resource lookup, because there the payload is staged into
    /// `Contents/Resources/` instead.
    ///
    /// The Mach-O inside the wrapper is what gets injected, not the
    /// `.framework` directory: `dlopen` of a directory fails.
    private static func payloadURL(inFrameworksAt frameworksURL: URL) -> URL? {
        let binaryURL = frameworksURL
            .appendingPathComponent("RuntimeViewerServer.framework", isDirectory: true)
            .appendingPathComponent("RuntimeViewerServer")
        return FileManager.default.fileExists(atPath: binaryURL.path) ? binaryURL : nil
    }
    #endif
}
