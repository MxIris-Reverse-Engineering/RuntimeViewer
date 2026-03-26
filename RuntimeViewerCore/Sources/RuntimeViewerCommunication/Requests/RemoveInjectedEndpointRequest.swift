#if os(macOS)

public import Foundation

/// Removes an injected app's endpoint from the Mach Service daemon.
///
/// Sent by the Host app when a reconnection attempt fails, indicating
/// the injected process has likely exited (backup for PID monitoring).
public struct RemoveInjectedEndpointRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.RemoveInjectedEndpoint"

    public typealias Response = VoidResponse

    public let pid: pid_t

    public init(pid: pid_t) {
        self.pid = pid
    }
}

#endif
