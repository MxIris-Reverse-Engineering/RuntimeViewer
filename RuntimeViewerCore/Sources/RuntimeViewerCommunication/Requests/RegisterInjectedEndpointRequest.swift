#if os(macOS)

public import Foundation
public import SwiftyXPC

/// Registers an injected app's XPC endpoint with the Mach Service daemon.
///
/// Sent by the injected app after its initial XPC connection succeeds.
/// The daemon starts monitoring the PID and auto-removes the endpoint on process exit.
public struct RegisterInjectedEndpointRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.RegisterInjectedEndpoint"

    public typealias Response = VoidResponse

    public let pid: pid_t
    public let appName: String
    public let bundleIdentifier: String
    public let endpoint: SwiftyXPC.XPCEndpoint

    public init(pid: pid_t, appName: String, bundleIdentifier: String, endpoint: SwiftyXPC.XPCEndpoint) {
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.endpoint = endpoint
    }
}

#endif
