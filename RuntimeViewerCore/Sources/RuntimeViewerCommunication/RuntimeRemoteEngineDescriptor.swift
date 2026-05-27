public import Foundation
import MetaCodable

@Codable
public struct RuntimeRemoteEngineDescriptor: Hashable, Sendable {
    public let engineID: String
    public let source: RuntimeSource
    public let hostName: String
    public let originChain: [String]
    public let directTCPHost: String
    public let directTCPPort: UInt16
    @Default(RuntimeDeviceMetadata.current)
    public let metadata: RuntimeDeviceMetadata
    public let iconData: Data?

    public init(
        engineID: String,
        source: RuntimeSource,
        hostName: String,
        originChain: [String],
        directTCPHost: String,
        directTCPPort: UInt16,
        metadata: RuntimeDeviceMetadata = .current,
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
}
