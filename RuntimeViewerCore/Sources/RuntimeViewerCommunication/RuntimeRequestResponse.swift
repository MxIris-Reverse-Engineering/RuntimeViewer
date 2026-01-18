import Foundation
import OSLog

public let RuntimeViewerMachServiceName = "com.mxiris.runtimeviewer.service"

public protocol RuntimeRequest: Codable {
    associatedtype Response: RuntimeResponse

    static var identifier: String { get }
}

public protocol RuntimeResponse: Codable {}

public struct VoidResponse: RuntimeResponse, Codable {
    public init() {}

    public static let empty: VoidResponse = .init()
}
