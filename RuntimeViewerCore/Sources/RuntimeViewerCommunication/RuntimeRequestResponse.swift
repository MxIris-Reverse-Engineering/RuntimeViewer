import Foundation
import OSLog

#if DEBUG
public let RuntimeViewerMachServiceName = "dev.mxiris.runtimeviewer.service"
#else
public let RuntimeViewerMachServiceName = "com.mxiris.runtimeviewer.service"
#endif

/// Protocol version shared between the app and the helper service daemon.
/// Bump this whenever the service binary changes in a way that requires reinstallation.
public let RuntimeViewerServiceVersion: String = "1.0.0"

public protocol RuntimeRequest: Codable {
    associatedtype Response: RuntimeResponse

    static var identifier: String { get }
}

public protocol RuntimeResponse: Codable {}

public struct VoidResponse: RuntimeResponse, Codable {
    public init() {}

    public static let empty: VoidResponse = .init()
}
