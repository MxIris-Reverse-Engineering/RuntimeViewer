import Foundation
import OSLog
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
public import HelperCommunication
#endif

#if DEBUG

/// In debug builds the helper-daemon mach-service identity is chosen by `runtimeViewerIsARM64EVariant`,
/// which each executable entry point (app / daemon / injected server) flips on for the
/// Debug-arm64e variant via `#if RUNTIMEVIEWER_ARM64E`. The arm64e variant cannot be detected
/// inside this SwiftPM package: custom build conditions don't reach package targets, and the
/// running architecture isn't a reliable signal (the app slice stays arm64 while the daemon /
/// injected slices are arm64e). Release is a fixed compile-time constant.
nonisolated(unsafe) public var runtimeViewerIsARM64EVariant = false

/// Mach service name shared by the app (client) and the helper daemon (server).
public var RuntimeViewerMachServiceName: String {
    runtimeViewerIsARM64EVariant
        ? "dev.arm64e.mxiris.runtimeviewer.service"
        : "dev.mxiris.runtimeviewer.service"
}

#else

/// Mach service name shared by the app (client) and the helper daemon (server).
public let RuntimeViewerMachServiceName = "com.mxiris.runtimeviewer.service"

#endif

/// Protocol version shared between the app and the helper service daemon.
/// Bump this whenever the service binary changes in a way that requires reinstallation.
public let RuntimeViewerServiceVersion: String = "1.4.0"

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
