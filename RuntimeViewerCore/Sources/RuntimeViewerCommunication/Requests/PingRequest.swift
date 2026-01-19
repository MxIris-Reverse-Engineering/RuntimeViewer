#if os(macOS)

import Foundation
import Version

public struct PingRequest: Codable, RuntimeRequest {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.RuntimeViewerService.Ping"

    public init() {}
}

#endif
