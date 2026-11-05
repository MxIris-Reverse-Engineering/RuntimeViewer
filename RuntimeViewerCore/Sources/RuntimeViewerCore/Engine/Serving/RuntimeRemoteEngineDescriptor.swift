public import Foundation
import MetaCodable
// `RuntimeSource` and `RuntimeDeviceMetadata` are stored properties, so they
// have to be visible to anyone holding a descriptor.
public import RuntimeViewerCommunication

/// One engine, as advertised to a peer that may mirror it.
///
/// Lives in this module rather than in `RuntimeViewerCommunication` because
/// "engine" is not a concept the connection layer has — that layer knows about
/// connections, sources and message channels, and never touched this type.
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

    /// An opaque identity for the advertised engine that survives the peer
    /// relaunching, forwarded verbatim.
    ///
    /// Distinct from ``engineID``, which is a *routing* address: it embeds
    /// `source.identifier`, and for a Bonjour peer that carries a process
    /// identifier, so it changes every time the peer restarts. This one does
    /// not, which is what lets a receiver file long-lived records against the
    /// engine and still find them next time.
    ///
    /// **This layer does not parse it and must not start.** The string is
    /// minted by the advertising side and means something only to the layer
    /// above; keeping it opaque here is what stops a transport type from
    /// growing opinions about how its callers store things.
    ///
    /// Carried alongside ``source`` rather than folded into it because
    /// `RuntimeSource` hand-writes its own `Equatable` and is used as a
    /// dictionary key upstream. Adding an identity field there forces a choice
    /// between leaving it out of equality — where it settles nothing — and
    /// putting it in, which makes every key already stored (decoding with the
    /// field absent) unequal to the live one.
    ///
    /// Empty when the peer predates this field, leaving the receiver to
    /// reconstruct what it can from ``source`` alone.
    @Default("")
    public let stableIdentity: String

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
        stableIdentity: String = "",
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
        self.stableIdentity = stableIdentity
        self.hostName = hostName
        self.originChain = originChain
        self.directTCPHost = directTCPHost
        self.directTCPPort = directTCPPort
        self.metadata = metadata
        self.iconData = iconData
    }
}
