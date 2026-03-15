#if os(macOS)

public import Foundation

public struct OpenApplicationRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.OpenApplicationRequest"

    public typealias Response = VoidResponse

    public let url: URL

    public let callerBundleIdentifier: String

    public init(url: URL, callerBundleIdentifier: String) {
        self.url = url
        self.callerBundleIdentifier = callerBundleIdentifier
    }
}

#endif
