#if !(canImport(AppKit) && !targetEnvironment(macCatalyst))

/// Non-macOS platforms keep a local `VoidResponse`. On macOS the daemon-bound request
/// types use `HelperCommunication.VoidResponse` from swift-helper-service instead.
public struct VoidResponse: RuntimeResponse {
    public init() {}

    public static let empty: VoidResponse = .init()
}

#endif
