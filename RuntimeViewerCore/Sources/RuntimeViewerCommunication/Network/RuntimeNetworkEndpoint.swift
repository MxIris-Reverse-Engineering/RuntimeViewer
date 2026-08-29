import Foundation
import Network

public struct RuntimeNetworkEndpoint: Sendable, Hashable {
    public let name: String
    public let instanceID: String?
    public let hostName: String?
    public let deviceMetadata: RuntimeDeviceMetadata?

    /// Device-level identifier from the TXT record. Groups every endpoint on
    /// one device into a single section. `nil` for peers predating the key.
    public let deviceID: String?

    /// Display name of the advertising process, from the TXT record.
    /// `nil` for peers predating the key.
    public let processName: String?

    /// Process identifier of the advertising process, from the TXT record.
    /// `nil` for peers predating the key.
    public let processIdentifier: String?

    let endpoint: NWEndpoint

    /// Process-level key used for deduplication and reconnect bookkeeping.
    ///
    /// The service name cannot serve here: an iOS peer advertises one name per
    /// *device*, so a second injected process on the same simulator would be
    /// mistaken for a duplicate of the first and never connect. Peers that
    /// don't publish the new keys fall back to the name, which is what they
    /// have always been keyed by.
    public var uniqueKey: String {
        guard let deviceID, let processIdentifier else { return name }
        return "\(deviceID)-\(processIdentifier)"
    }

    /// What a `.changed` browse result means for the endpoint list.
    public enum MetadataChange: Equatable, Sendable {
        /// The advertisement now describes a *different* process: the old
        /// endpoint is gone and a new one has taken its place.
        case replacesEndpoint
        /// Same process; some other published field moved.
        case sameEndpoint
    }

    /// Classifies a `.changed` browse result by whether the peer's *identity*
    /// moved — not by which flags `NWBrowser` set, because `.metadataChanged`
    /// fires for any TXT edit, including ones that leave the process alone.
    ///
    /// This exists because `.changed` is now the ordinary shape of a peer
    /// relaunching. The advertised name was deliberately made launch-stable, so
    /// a restarted process keeps its service instance name and moves only its
    /// TXT record — which `NWBrowser` reports as a change to an existing
    /// result rather than a removal followed by an addition.
    public static func metadataChange(
        from previous: RuntimeNetworkEndpoint,
        to current: RuntimeNetworkEndpoint
    ) -> MetadataChange {
        previous.uniqueKey == current.uniqueKey ? .sameEndpoint : .replacesEndpoint
    }

    init(
        name: String,
        instanceID: String? = nil,
        hostName: String? = nil,
        deviceMetadata: RuntimeDeviceMetadata? = nil,
        deviceID: String? = nil,
        processName: String? = nil,
        processIdentifier: String? = nil,
        endpoint: NWEndpoint
    ) {
        self.name = name
        self.instanceID = instanceID
        self.hostName = hostName
        self.deviceMetadata = deviceMetadata
        self.deviceID = deviceID
        self.processName = processName
        self.processIdentifier = processIdentifier
        self.endpoint = endpoint
    }

    // Exclude instanceID and hostName from equality — they are metadata, not identity.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.endpoint == rhs.endpoint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(endpoint)
    }
}

extension RuntimeNetworkEndpoint {
    /// Builds an endpoint from a browse result, reading every TXT field the
    /// peer published. Keeping this in one place is what stops the `.added` and
    /// `.removed` branches from parsing different subsets — they must agree, or
    /// an endpoint would be keyed one way going in and another coming out.
    init(name: String, result: NWBrowser.Result) {
        self.init(
            name: name,
            instanceID: RuntimeNetworkBonjour.instanceID(from: result.metadata),
            hostName: RuntimeNetworkBonjour.hostName(from: result.metadata),
            deviceMetadata: RuntimeNetworkBonjour.deviceMetadata(from: result.metadata),
            deviceID: RuntimeNetworkBonjour.deviceID(from: result.metadata),
            processName: RuntimeNetworkBonjour.processName(from: result.metadata),
            processIdentifier: RuntimeNetworkBonjour.processIdentifier(from: result.metadata),
            endpoint: result.endpoint
        )
    }
}
