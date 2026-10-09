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

extension RuntimeNetworkRequestError {
    /// How a peer words its reply to a command it has no handler for. Every
    /// release since 2.1.0 answers with exactly this prefix and the command
    /// name, and nothing else: matching the text is the only way to recognise
    /// a peer older than a command, so the channel that writes the reply and
    /// the code that reads it share this constant.
    public static let unknownCommandMessagePrefix = "No handler registered for "

    /// The peer does not know the command: it predates it, or a peer it
    /// forwards to does.
    public var isUnknownCommand: Bool {
        message.hasPrefix(Self.unknownCommandMessagePrefix)
    }
}
