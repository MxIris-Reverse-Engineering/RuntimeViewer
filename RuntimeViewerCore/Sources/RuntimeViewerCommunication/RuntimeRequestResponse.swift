import Foundation
import OSLog
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
public import HelperCommunication
#endif

/// Mach service name shared by the app (client) and the helper daemon (server).
///
/// Resolved at runtime from a single build-time source (`RUNTIME_VIEWER_SERVICE_NAME`),
/// so per-configuration variants (including Debug-arm64e) stay in sync without a
/// compile flag — which cannot reach this SPM package anyway:
/// - the daemon process receives it via its launchd plist `EnvironmentVariables`;
/// - the app process reads it from its `Info.plist` (`RuntimeViewerServiceName`).
/// The `#if DEBUG` values are only a fallback for contexts where neither is present
/// (e.g. unit tests).
public let RuntimeViewerMachServiceName: String = {
    if let injected = ProcessInfo.processInfo.environment["RUNTIME_VIEWER_SERVICE_NAME"], !injected.isEmpty {
        return injected
    }
    if let fromBundle = Bundle.main.object(forInfoDictionaryKey: "RuntimeViewerServiceName") as? String, !fromBundle.isEmpty {
        return fromBundle
    }
    #if DEBUG
    return "dev.mxiris.runtimeviewer.service"
    #else
    return "com.mxiris.runtimeviewer.service"
    #endif
}()

/// Protocol version shared between the app and the helper service daemon.
/// Bump this whenever the service binary changes in a way that requires reinstallation.
public let RuntimeViewerServiceVersion: String = "1.2.0"

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

/// On macOS, `RuntimeRequest` is a refinement of `HelperCommunication.Request` so that any
/// daemon-bound business request can be mounted directly onto a lib `HelperService` /
/// `HelperPeerClient` / `HelperPeerServer`. The `RuntimeResponse: Codable & Sendable`
/// constraint is what lets the inherited `associatedtype Response: Codable & Sendable`
/// from `HelperCommunication.Request` be satisfied.
///
/// Business request types (now defined in swift-helper-service) gain `RuntimeRequest`
/// conformance retroactively — see `Requests+RuntimeRequest.swift`.
public protocol RuntimeRequest: HelperCommunication.Request where Response: RuntimeResponse {}

#else

public protocol RuntimeRequest: Codable, Sendable {
    associatedtype Response: RuntimeResponse

    static var identifier: String { get }
}

#endif

public protocol RuntimeResponse: Codable, Sendable {}

#if !(canImport(AppKit) && !targetEnvironment(macCatalyst))

/// Non-macOS platforms keep a local `VoidResponse`. On macOS the daemon-bound request
/// types use `HelperCommunication.VoidResponse` from swift-helper-service instead.
public struct VoidResponse: RuntimeResponse {
    public init() {}

    public static let empty: VoidResponse = .init()
}

#endif
