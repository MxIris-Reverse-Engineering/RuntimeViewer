public import Foundation
import MetaCodable

@Codable
public struct RuntimeRemoteEngineDescriptor: Hashable, Sendable {
    public let engineID: String
    public let source: RuntimeSource

    /// The advertised engine's host identifier — the same value the forwarder
    /// holds in `hostInfo.hostID`, so a mirror of this engine lands in the same
    /// section as a direct route to it.
    ///
    /// Cannot be derived from `originChain.first`: that is an *instance* ID,
    /// scoped to one installation, whereas a host is a device. The two used to
    /// coincide because one device ran one installation; a device carrying
    /// several injected payloads breaks that. Empty when the peer predates this
    /// field, in which case the receiver falls back to `originChain.first`.
    @Default("")
    public let hostID: String
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
        hostID: String = "",
        hostName: String,
        originChain: [String],
        directTCPHost: String,
        directTCPPort: UInt16,
        metadata: RuntimeDeviceMetadata = .current,
        iconData: Data? = nil
    ) {
        self.engineID = engineID
        self.source = source
        self.hostID = hostID
        self.hostName = hostName
        self.originChain = originChain
        self.directTCPHost = directTCPHost
        self.directTCPPort = directTCPPort
        self.metadata = metadata
        self.iconData = iconData
    }
}
