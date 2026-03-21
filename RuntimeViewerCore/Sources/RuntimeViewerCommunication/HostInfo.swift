import Foundation

public struct HostInfo: Codable, Hashable, Sendable {
    public let hostID: String
    public let hostName: String

    public init(hostID: String, hostName: String) {
        self.hostID = hostID
        self.hostName = hostName
    }
}
