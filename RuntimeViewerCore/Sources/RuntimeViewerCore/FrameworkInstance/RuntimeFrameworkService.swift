#if os(macOS)

public import Foundation
public import RuntimeViewerCommunication

/// The framework service, as seen from both of its ends.
///
/// Every Load Frameworks runs in a process of its own: the app embeds
/// `RuntimeViewerFrameworkService.xpc`, a service that declares
/// `_MultipleInstances` and carries the library validation exception, and the
/// engine of a window that loads frameworks connects with
/// ``credential(for:)`` — to an instance of the service nobody else reaches.
/// The connection's first `hello` says which instance it is
/// (``RuntimeFrameworkInstance``); the instance serves an engine over its own
/// images through ``RuntimeFrameworkServiceHost``, and the frameworks are
/// loaded into it with the engine's load command. The app's `Info.plist` names
/// the service under ``bundleIdentifierInfoDictionaryKey``, so only a process
/// whose bundle embeds it gets a credential.
public enum RuntimeFrameworkService {
    /// The app `Info.plist` key carrying the embedded service's bundle
    /// identifier. Filled from `RUNTIME_VIEWER_FRAMEWORK_SERVICE_BUNDLE_IDENTIFIER`
    /// at build time, one value per configuration.
    public static let bundleIdentifierInfoDictionaryKey = "RuntimeViewerFrameworkServiceBundleIdentifier"

    /// The bundle identifier of the service this process embeds, or `nil`
    /// when its bundle names none.
    public static var embeddedServiceBundleIdentifier: String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: bundleIdentifierInfoDictionaryKey) as? String,
              !identifier.isEmpty
        else { return nil }
        return identifier
    }

    /// What the engine of `instance` connects with: an instance of the
    /// embedded service of its own — or `nil` when this process embeds no
    /// framework service.
    public static func credential(for instance: RuntimeFrameworkInstance) throws -> RuntimeConnectionCredential? {
        guard let bundleIdentifier = embeddedServiceBundleIdentifier else { return nil }
        return .xpcService(.dedicatedInstance(bundleIdentifier: bundleIdentifier, launchPayload: try launchPayload(for: instance)))
    }

    /// What the first `hello` to an instance carries for `instance`.
    public static func launchPayload(for instance: RuntimeFrameworkInstance) throws -> Data {
        try JSONEncoder().encode(instance)
    }

    /// The instance a launch payload names.
    public static func instance(fromLaunchPayload payload: Data) throws -> RuntimeFrameworkInstance {
        try JSONDecoder().decode(RuntimeFrameworkInstance.self, from: payload)
    }
}

#endif
