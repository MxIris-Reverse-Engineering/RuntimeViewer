public import Foundation

public struct OpenApplicationRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.OpenApplicationRequest"

    public typealias Response = VoidResponse

    public let url: URL

    public init(url: URL) {
        self.url = url
    }
}
