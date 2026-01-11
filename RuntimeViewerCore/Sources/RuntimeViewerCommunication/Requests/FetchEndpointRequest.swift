#if os(macOS)

import Foundation
public import SwiftyXPC

public struct FetchEndpointRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.FetchEndpoint"

    public struct Response: RuntimeResponse, Codable {
        public let endpoint: SwiftyXPC.XPCEndpoint

        public init(endpoint: SwiftyXPC.XPCEndpoint) {
            self.endpoint = endpoint
        }
    }

    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}
#endif
