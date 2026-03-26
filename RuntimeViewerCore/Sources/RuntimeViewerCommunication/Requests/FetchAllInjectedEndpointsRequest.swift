#if os(macOS)

import Foundation

/// Fetches all currently registered injected app endpoints from the Mach Service daemon.
///
/// Sent by the Host app on startup to discover already-injected processes for reconnection.
public struct FetchAllInjectedEndpointsRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.FetchAllInjectedEndpoints"

    public struct Response: RuntimeResponse, Codable {
        public let endpoints: [InjectedEndpointInfo]

        public init(endpoints: [InjectedEndpointInfo]) {
            self.endpoints = endpoints
        }
    }

    public init() {}
}

#endif
