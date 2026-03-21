#if os(macOS)

public import Foundation

public struct OpenApplicationRequest: Codable, RuntimeRequest {
    public static let identifier: String = "com.JH.RuntimeViewerService.OpenApplicationRequest"

    public typealias Response = VoidResponse

    public let url: URL

    public let callerPID: Int32

    public init(url: URL, callerPID: Int32) {
        self.url = url
        self.callerPID = callerPID
    }
}

#endif
