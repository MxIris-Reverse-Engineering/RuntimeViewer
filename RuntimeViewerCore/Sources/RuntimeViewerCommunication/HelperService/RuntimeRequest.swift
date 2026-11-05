#if canImport(AppKit) && !targetEnvironment(macCatalyst)
public import HelperCommunication
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

/// On macOS, `RuntimeRequest` is a refinement of `HelperCommunication.Request` so that any
/// daemon-bound business request can be mounted directly onto a lib `HelperService` /
/// `HelperPeerClient` / `HelperPeerServer`. The `RuntimeResponse: Codable & Sendable`
/// constraint is what lets the inherited `associatedtype Response: Codable & Sendable`
/// from `HelperCommunication.Request` be satisfied.
///
/// Business request types (now defined in swift-helper-service, the endpoint registry's in
/// swift-injection-peer) gain `RuntimeRequest` conformance retroactively — see
/// `RuntimeRequests.swift`.
public protocol RuntimeRequest: HelperCommunication.Request where Response: RuntimeResponse {}

#else

public protocol RuntimeRequest: Codable, Sendable {
    associatedtype Response: RuntimeResponse

    static var identifier: String { get }
}

#endif
