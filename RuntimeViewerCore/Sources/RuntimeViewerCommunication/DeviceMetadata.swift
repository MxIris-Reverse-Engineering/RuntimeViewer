import Foundation

public struct DeviceMetadata: Codable, Hashable, Sendable {
    public let modelIdentifier: String
    public let osVersion: String
    public let isSimulator: Bool
    public var additionalInfo: [String: String]

    public init(
        modelIdentifier: String,
        osVersion: String,
        isSimulator: Bool = false,
        additionalInfo: [String: String] = [:]
    ) {
        self.modelIdentifier = modelIdentifier
        self.osVersion = osVersion
        self.isSimulator = isSimulator
        self.additionalInfo = additionalInfo
    }
}

extension DeviceMetadata {
    public static let current: DeviceMetadata = {
        let modelIdentifier = _readModelIdentifier()
        let osVersion = _formatOSVersion()
        let isSimulator: Bool
        #if targetEnvironment(simulator)
        isSimulator = true
        #else
        isSimulator = false
        #endif
        return DeviceMetadata(
            modelIdentifier: modelIdentifier,
            osVersion: osVersion,
            isSimulator: isSimulator
        )
    }()

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        modelIdentifier = try container.decode(String.self, forKey: .modelIdentifier)
        osVersion = try container.decode(String.self, forKey: .osVersion)
        isSimulator = try container.decodeIfPresent(Bool.self, forKey: .isSimulator) ?? false
        additionalInfo = try container.decodeIfPresent([String: String].self, forKey: .additionalInfo) ?? [:]
    }

    private static func _readModelIdentifier() -> String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Unknown" }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
        #endif
    }

    private static func _formatOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if os(macOS)
        return "macOS \(versionString)"
        #elseif os(iOS)
        #if targetEnvironment(macCatalyst)
        return "macCatalyst \(versionString)"
        #else
        return "iOS \(versionString)"
        #endif
        #elseif os(watchOS)
        return "watchOS \(versionString)"
        #elseif os(tvOS)
        return "tvOS \(versionString)"
        #elseif os(visionOS)
        return "visionOS \(versionString)"
        #else
        return "Unknown \(versionString)"
        #endif
    }
}
