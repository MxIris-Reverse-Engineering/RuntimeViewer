#if os(macOS)

public import Foundation
public import RuntimeViewerCommunication

/// The file service, as seen from both of its ends.
///
/// Every file is read in a process of its own: the app embeds
/// `RuntimeViewerFileService.xpc`, a service that declares
/// `_MultipleInstances`, and the engine reading a file connects with
/// ``credential(for:)`` — to an instance of the service nobody else reaches.
/// The connection's first `hello` carries the file; the instance reads it and
/// serves what it finds through ``RuntimeFileServiceHost``. The app's
/// `Info.plist` names the service under ``bundleIdentifierInfoDictionaryKey``,
/// so only a process whose bundle embeds it gets a credential.
public enum RuntimeFileService {
    /// The app `Info.plist` key carrying the embedded service's bundle
    /// identifier. Filled from `RUNTIME_VIEWER_FILE_SERVICE_BUNDLE_IDENTIFIER`
    /// at build time, one value per configuration.
    public static let bundleIdentifierInfoDictionaryKey = "RuntimeViewerFileServiceBundleIdentifier"

    /// The bundle identifier of the service this process embeds, or `nil`
    /// when its bundle names none.
    public static var embeddedServiceBundleIdentifier: String? {
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: bundleIdentifierInfoDictionaryKey) as? String,
              !identifier.isEmpty
        else { return nil }
        return identifier
    }

    /// What an engine reading `file` connects with: an instance of the
    /// embedded service of its own, told which file to read — or `nil` when
    /// this process embeds no file service.
    public static func credential(for file: RuntimeFile) throws -> RuntimeConnectionCredential? {
        guard let bundleIdentifier = embeddedServiceBundleIdentifier else { return nil }
        return .xpcService(.dedicatedInstance(bundleIdentifier: bundleIdentifier, launchPayload: try launchPayload(for: file)))
    }

    /// What the first `hello` to an instance carries for `file`.
    public static func launchPayload(for file: RuntimeFile) throws -> Data {
        try JSONEncoder().encode(file)
    }

    /// The file a launch payload names.
    public static func file(fromLaunchPayload payload: Data) throws -> RuntimeFile {
        try JSONDecoder().decode(RuntimeFile.self, from: payload)
    }
}

#endif
