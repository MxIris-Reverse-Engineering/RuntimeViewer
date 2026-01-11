#if os(macOS)

import Foundation
public import SwiftyXPC

public struct RegisterEndpointRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.RegisterEndpoint"

    public typealias Response = VoidResponse

    public let identifier: String

    public let endpoint: SwiftyXPC.XPCEndpoint

    public init(identifier: String, endpoint: SwiftyXPC.XPCEndpoint) {
        self.identifier = identifier
        self.endpoint = endpoint
    }
}

#endif
