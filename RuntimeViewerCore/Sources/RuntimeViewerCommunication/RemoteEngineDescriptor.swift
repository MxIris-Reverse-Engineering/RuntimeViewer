public import Foundation

public struct RemoteEngineDescriptor: Codable, Hashable, Sendable {
    public let engineID: String
    public let source: RuntimeSource
    public let hostName: String
    public let originChain: [String]
    public let directTCPHost: String
    public let directTCPPort: UInt16
    public let metadata: DeviceMetadata
    public let iconData: Data?

    public init(
        engineID: String,
        source: RuntimeSource,
        hostName: String,
        originChain: [String],
        directTCPHost: String,
        directTCPPort: UInt16,
        metadata: DeviceMetadata = .current,
        iconData: Data? = nil
    ) {
        self.engineID = engineID
        self.source = source
        self.hostName = hostName
        self.originChain = originChain
        self.directTCPHost = directTCPHost
        self.directTCPPort = directTCPPort
        self.metadata = metadata
        self.iconData = iconData
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engineID = try container.decode(String.self, forKey: .engineID)
        source = try container.decode(RuntimeSource.self, forKey: .source)
        hostName = try container.decode(String.self, forKey: .hostName)
        originChain = try container.decode([String].self, forKey: .originChain)
        directTCPHost = try container.decode(String.self, forKey: .directTCPHost)
        directTCPPort = try container.decode(UInt16.self, forKey: .directTCPPort)
        metadata = try container.decodeIfPresent(DeviceMetadata.self, forKey: .metadata) ?? .current
        iconData = try container.decodeIfPresent(Data.self, forKey: .iconData)
    }
}
