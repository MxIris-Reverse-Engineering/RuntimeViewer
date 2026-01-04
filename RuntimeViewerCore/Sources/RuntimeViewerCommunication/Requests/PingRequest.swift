import Foundation

public struct PingRequest: Codable, RuntimeRequest {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.RuntimeViewerService.Ping"

    public init() {}
}
