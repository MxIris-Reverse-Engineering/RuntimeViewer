import Foundation
// `RuntimeDeviceMetadata` is a stored property, and it stays in the connection
// layer because Bonjour publishes it and `RuntimeNetworkEndpoint` carries it.
public import RuntimeViewerCommunication

/// Which machine an engine belongs to.
///
/// Lives here rather than in `RuntimeViewerCommunication` for the same reason
/// as ``RuntimeRemoteEngineDescriptor``: the connection layer never referenced
/// it, and grouping engines by host is not a question that layer asks.
public struct RuntimeHostInfo: Codable, Hashable, Sendable {
    public let hostID: String
    public let hostName: String
    public let metadata: RuntimeDeviceMetadata

    public init(hostID: String, hostName: String, metadata: RuntimeDeviceMetadata = .current) {
        self.hostID = hostID
        self.hostName = hostName
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(String.self, forKey: .hostID)
        hostName = try container.decode(String.self, forKey: .hostName)
        metadata = try container.decodeIfPresent(RuntimeDeviceMetadata.self, forKey: .metadata) ?? .current
    }
}
