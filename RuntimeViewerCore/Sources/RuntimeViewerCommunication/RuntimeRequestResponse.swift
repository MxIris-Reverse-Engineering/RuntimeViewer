import Foundation
import OSLog

#if DEBUG
public let RuntimeViewerMachServiceName = "dev.mxiris.runtimeviewer.service"
#else
public let RuntimeViewerMachServiceName = "com.mxiris.runtimeviewer.service"
#endif

public protocol RuntimeRequest: Codable {
    associatedtype Response: RuntimeResponse

    static var identifier: String { get }
}

public protocol RuntimeResponse: Codable {}

public struct VoidResponse: RuntimeResponse, Codable {
    public init() {}

    public static let empty: VoidResponse = .init()
}
