public import Foundation

public enum RuntimeNetworkError: Error {
    case notConnected
    case invalidPort
    case receiveFailed
}

/// A handler failure as it crosses a socket: the description the serving peer
/// wrote for it. `LocalizedError`, so that it reads as that description
/// wherever it is shown, instead of "The operation couldn't be completed.
/// (RuntimeViewerCommunication.RuntimeNetworkRequestError error 1.)".
public struct RuntimeNetworkRequestError: Error, Codable, LocalizedError {
    public let message: String

    public var errorDescription: String? { message }
}
