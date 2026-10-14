import Foundation
import RuntimeViewerCommunication

/// The Mac Catalyst runtime's XPC service, as seen from the process that
/// ships it.
///
/// "My Mac (Mac Catalyst)" used to be a helper application that the helper
/// daemon opened and that connected back through it. The app now embeds a
/// Mac Catalyst XPC service (`RuntimeViewerCatalystService.xpc`) instead,
/// which launchd starts on the first message and starts again after it
/// exits. Which process takes which path is decided by the bundle, the way
/// `LocalRuntimeService` in RuntimeViewerCore decides it for "My Mac": the
/// app's `Info.plist` names the service it embeds under
/// ``bundleIdentifierInfoDictionaryKey``, so the app connects its Catalyst
/// engine with ``embeddedServiceCredential``. A process without the key —
/// the standalone `runtime-viewer-cli` host — gets `nil` and keeps launching
/// the helper application through the daemon: launchd only finds an embedded
/// service in the calling process's own bundle, and that process is the app.
///
/// The service and the helper application are both shells around
/// `RuntimeViewerCatalystHelperPlugin`, which does the work on either path.
public enum MacCatalystRuntimeService {
    /// The app `Info.plist` key carrying the embedded service's bundle
    /// identifier. Filled from `RUNTIME_VIEWER_CATALYST_SERVICE_BUNDLE_IDENTIFIER`
    /// at build time, one value per configuration.
    public static let bundleIdentifierInfoDictionaryKey = "RuntimeViewerCatalystServiceBundleIdentifier"

    /// The bundle identifier of the Mac Catalyst service this process embeds,
    /// or `nil` when its bundle names none.
    public static var embeddedServiceBundleIdentifier: String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: bundleIdentifierInfoDictionaryKey) as? String,
              !identifier.isEmpty
        else { return nil }
        return identifier
    }

    /// What the Mac Catalyst client engine connects with: the embedded
    /// service, or `nil` for a process that launches the helper application
    /// instead.
    public static var embeddedServiceCredential: RuntimeConnectionCredential? {
        #if os(macOS)
        return embeddedServiceBundleIdentifier.map { .xpcService(.bundleIdentifier($0)) }
        #else
        return nil
        #endif
    }
}
