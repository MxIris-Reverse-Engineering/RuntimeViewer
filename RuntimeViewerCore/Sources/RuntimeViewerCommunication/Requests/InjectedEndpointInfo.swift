#if os(macOS)

public import Foundation
public import SwiftyXPC

/// Metadata for an injected app's registered XPC endpoint.
///
/// Stored by the Mach Service daemon and returned to the Host app
/// for reconnecting to already-injected processes after restart.
public struct InjectedEndpointInfo: Codable, Sendable {
    /// The process identifier of the injected app.
    public let pid: pid_t

    /// The display name of the injected app.
    public let appName: String

    /// The bundle identifier of the injected app.
    public let bundleIdentifier: String

    /// The XPC listener endpoint of the injected app's runtime engine server.
    public let endpoint: SwiftyXPC.XPCEndpoint

    public init(pid: pid_t, appName: String, bundleIdentifier: String, endpoint: SwiftyXPC.XPCEndpoint) {
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.endpoint = endpoint
    }
}

#endif
