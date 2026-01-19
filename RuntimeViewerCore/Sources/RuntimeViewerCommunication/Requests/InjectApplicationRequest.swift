#if os(macOS)

public import Foundation

public struct InjectApplicationRequest: Codable, RuntimeRequest {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.RuntimeViewerService.InjectApplication"

    public let pid: pid_t

    public let dylibURL: URL

    public init(pid: pid_t, dylibURL: URL) {
        self.pid = pid
        self.dylibURL = dylibURL
    }
}

#endif
