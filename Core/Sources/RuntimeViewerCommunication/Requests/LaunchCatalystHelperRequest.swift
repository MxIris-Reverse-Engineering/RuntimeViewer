import Foundation

public struct LaunchCatalystHelperRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.LaunchCatalystHelper"

    public typealias Response = VoidResponse

    public let helperURL: URL

    public init(helperURL: URL) {
        self.helperURL = helperURL
    }
}
