#if os(macOS)

public import Foundation
import FoundationToolbox
import Combine
import SwiftyXPC
import HelperCommunication

/// A reference to an anonymous `XPCListener`, opaque outside this module so
/// SwiftyXPC stays an implementation detail of the connection layer.
public struct RuntimeXPCServiceEndpoint: @unchecked Sendable {
    let underlying: SwiftyXPC.XPCEndpoint

    /// Test seam: a client connecting here behaves as one to a dedicated
    /// instance — its hellos carry this payload, and it reattaches behind a
    /// new connection. `nil` for a plain endpoint.
    let launchPayload: Data?

    init(_ underlying: SwiftyXPC.XPCEndpoint, launchPayload: Data? = nil) {
        self.underlying = underlying
        self.launchPayload = launchPayload
    }

    /// Test seam: this endpoint, reached the way a dedicated instance is.
    /// See ``launchPayload``.
    func carryingLaunchPayload(_ payload: Data) -> RuntimeXPCServiceEndpoint {
        RuntimeXPCServiceEndpoint(underlying, launchPayload: payload)
    }
}

#endif
