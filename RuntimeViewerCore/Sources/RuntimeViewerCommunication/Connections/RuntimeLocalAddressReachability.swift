import Foundation
import Combine
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import HelperCommunication
#endif

/// How this process can be reached by a connection's peer.
///
/// Two cases rather than an optional, because the negative one is read by a
/// user: an injection into a process on a device cannot proceed without an
/// address, and the difference between "that connection just dropped" and "that
/// connection is IPv6 and this transport dials IPv4" is the difference between
/// retrying and changing something.
public enum RuntimeLocalAddressReachability: Sendable, Hashable {
    /// The peer can dial this IPv4 address.
    case reachableAt(String)

    /// There is nothing for the peer to dial, and this is why — in words meant
    /// to be read as part of a sentence that already says what failed.
    case unknown(reason: String)

    public var address: String? {
        guard case .reachableAt(let address) = self else { return nil }
        return address
    }
}
