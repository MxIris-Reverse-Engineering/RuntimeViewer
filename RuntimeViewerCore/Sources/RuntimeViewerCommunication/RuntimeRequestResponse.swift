import Foundation
import OSLog
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
public import HelperCommunication
#endif

#if DEBUG
public let RuntimeViewerMachServiceName = "dev.mxiris.runtimeviewer.service"
#else
public let RuntimeViewerMachServiceName = "com.mxiris.runtimeviewer.service"
#endif

/// Protocol version shared between the app and the helper service daemon.
/// Bump this whenever the service binary changes in a way that requires reinstallation.
public let RuntimeViewerServiceVersion: String = "1.0.0"

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

/// On macOS, `RuntimeRequest` is a refinement of `HelperCommunication.Request` so that any
/// daemon-bound business request can be mounted directly onto a lib `HelperService` /
/// `BrokeredPeerClient` / `BrokeredPeerServer`. The `RuntimeResponse: Codable & Sendable`
/// constraint is what lets the inherited `associatedtype Response: Codable & Sendable`
/// from `HelperCommunication.Request` be satisfied.
public protocol RuntimeRequest: HelperCommunication.Request {
    associatedtype Response: RuntimeResponse
}

#else

public protocol RuntimeRequest: Codable, Sendable {
    associatedtype Response: RuntimeResponse

    static var identifier: String { get }
}

#endif

public protocol RuntimeResponse: Codable, Sendable {}

public struct VoidResponse: RuntimeResponse {
    public init() {}

    public static let empty: VoidResponse = .init()
}
