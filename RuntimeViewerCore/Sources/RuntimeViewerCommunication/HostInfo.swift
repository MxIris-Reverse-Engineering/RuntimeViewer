import Foundation

public struct HostInfo: Codable, Hashable, Sendable {
    public let hostID: String
    public let hostName: String
    public let metadata: DeviceMetadata

    public init(hostID: String, hostName: String, metadata: DeviceMetadata = .current) {
        self.hostID = hostID
        self.hostName = hostName
        self.metadata = metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try container.decode(String.self, forKey: .hostID)
        hostName = try container.decode(String.self, forKey: .hostName)
        metadata = try container.decodeIfPresent(DeviceMetadata.self, forKey: .metadata) ?? .current
    }
}
