import Foundation

public struct RemoteEngineDescriptor: Codable, Hashable, Sendable {
    public let engineID: String
    public let source: RuntimeSource
    public let hostName: String
    public let originChain: [String]
    public let directTCPHost: String
    public let directTCPPort: UInt16

    public init(
        engineID: String,
        source: RuntimeSource,
        hostName: String,
        originChain: [String],
        directTCPHost: String,
        directTCPPort: UInt16
    ) {
        self.engineID = engineID
        self.source = source
        self.hostName = hostName
        self.originChain = originChain
        self.directTCPHost = directTCPHost
        self.directTCPPort = directTCPPort
    }
}
