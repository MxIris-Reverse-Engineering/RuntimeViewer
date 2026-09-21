public import Foundation
public import RuntimeViewerCommunication

/// The local-runtime XPC service, as seen from the process that ships it.
///
/// "My Mac" — `RuntimeEngine.local` — used to dlopen and index every image
/// the user picked inside the app. Now the app embeds a plain XPC service
/// (`RuntimeViewerLocalRuntimeService.xpc`, no Mach service, no helper
/// daemon) that does that work, and the app's `.local` engine forwards to
/// it. Which process is which is decided by the bundle: the app's
/// `Info.plist` names the service it embeds under
/// ``bundleIdentifierInfoDictionaryKey``, and `RuntimeEngine.local` connects
/// with ``embeddedServiceCredential`` — a credential in the app, `nil`
/// everywhere else (the service itself, the standalone CLI host, the
/// Catalyst helper, a test), where the engine stays in process. There is
/// nothing to configure and nothing to set before first use, which is the
/// point: launchd only finds an embedded service in the calling process's
/// own bundle, so the bundle *is* the configuration.
///
/// The other half — the process the service runs — is
/// ``RuntimeLocalRuntimeServiceHost``.
public enum LocalRuntimeService {
    /// The app `Info.plist` key carrying the embedded service's bundle
    /// identifier. Filled from `RUNTIME_VIEWER_LOCAL_RUNTIME_SERVICE_BUNDLE_IDENTIFIER`
    /// at build time, one value per configuration.
    public static let bundleIdentifierInfoDictionaryKey = "RuntimeViewerLocalRuntimeServiceBundleIdentifier"

    /// The bundle identifier of the service this process embeds, or `nil`
    /// when its bundle names none.
    public static var embeddedServiceBundleIdentifier: String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: bundleIdentifierInfoDictionaryKey) as? String,
              !identifier.isEmpty
        else { return nil }
        return identifier
    }

    /// What `RuntimeEngine.local` connects with: the embedded service, or
    /// `nil` for an engine that does its own work.
    public static var embeddedServiceCredential: RuntimeConnectionCredential? {
        #if os(macOS)
        return embeddedServiceBundleIdentifier.map { .xpcService(.bundleIdentifier($0)) }
        #else
        return nil
        #endif
    }
}
