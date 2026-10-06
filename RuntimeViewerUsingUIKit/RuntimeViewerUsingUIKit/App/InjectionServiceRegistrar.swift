import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerInjection

#if RUNTIME_VIEWER_JAILBROKEN
import RuntimeViewerDeviceInjection
#endif

/// Installs the injection commands into the engine command table, and hands
/// over this process's injection implementation in the variant that has one.
///
/// **Both halves run in every variant; only the second is conditional.** The
/// commands go in unconditionally because the capability query is how a host
/// learns that a build cannot inject — a variant that registered nothing would
/// be indistinguishable from an app built before these commands existed, so a
/// device running a perfectly good ordinary build would read as unanswerable
/// instead of as `requiresJailbrokenVariant`.
///
/// `RUNTIME_VIEWER_JAILBROKEN`, which only the `RuntimeViewerUsingUIKit-JB`
/// target defines, decides the service. The file is in the synchronized group
/// all three app targets share, so the ordinary builds compile that half to
/// nothing, never link `RuntimeViewerDeviceInjection`, and leave
/// ``RuntimeInjection/service`` at `nil`. That is the meaningful state that
/// makes them answer `requiresJailbrokenVariant` rather than a lie about the
/// platform.
@Loggable
enum InjectionServiceRegistrar {
    /// Must run before any engine can be asked about its capabilities, so it
    /// goes first in `didFinishLaunchingWithOptions` — ahead of
    /// `RuntimeEngine.local` and the Bonjour server engine, either of which a
    /// host may query as soon as it is reachable. The commands are installed as
    /// a connection is set up, so "before any engine connects" is a hard
    /// requirement, not an ordering preference.
    static func registerIfAvailable() {
        RuntimeInjection.install(service: injectionService())
    }

    /// This variant's injection implementation, or `nil` when it has none.
    private static func injectionService() -> (any RuntimeInjectionService)? {
        #if RUNTIME_VIEWER_JAILBROKEN
        guard let frameworksURL = Bundle.main.privateFrameworksURL,
              let payloadURL = payloadURL(inFrameworksAt: frameworksURL)
        else {
            // A service is returned anyway: it reports a missing payload as its
            // own distinct reason, and that is more useful to a user than this
            // build pretending to be the ordinary variant.
            #log(.error, "Jailbroken variant found no embedded payload; injection will report it as unavailable")
            return RuntimeDeviceInjectionService(
                payloadURL: URL(fileURLWithPath: "/nonexistent/RuntimeViewerServer"),
                dependencyDirectoryURL: URL(fileURLWithPath: "/nonexistent", isDirectory: true),
            )
        }
        #log(.info, "Registering device injection service with payload at \(payloadURL.path, privacy: .public)")
        // The same directory serves as the dependency source: the payload
        // loads `@rpath/libswiftCompatibilitySpan.dylib`, which Xcode embeds
        // right beside it, and the staged copy has to carry it along.
        return RuntimeDeviceInjectionService(
            payloadURL: payloadURL,
            dependencyDirectoryURL: frameworksURL,
        )
        #else
        return nil
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
