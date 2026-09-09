import Foundation

/// Why a command did not produce a result. Travels on the wire and is what
/// `--json` prints on failure.
public struct CommandFailure: Codable, Sendable, Hashable, Error {
    public enum Code: String, Codable, Sendable, Hashable, CaseIterable {
        /// The host does not serve the requested source.
        case sourceUnavailable
        /// No image matched the path or short name.
        case imageNotFound
        /// The image exists but could not be loaded or indexed.
        case imageLoadFailed
        case typeNotFound
        /// A value the client sent is malformed (regular expression, specialization argument, path).
        case invalidArgument
        case specializationFailed
        case exportFailed
        /// The helper daemon is not installed or cannot be reached; `attach`
        /// and the Catalyst runtime need it.
        case helperUnavailable
        /// No RuntimeViewer application bundle was found to take the injection
        /// payload or the Catalyst helper from.
        case applicationBundleNotFound
        /// No running process matched the identifier or name.
        case processNotFound
        /// Several running processes share the name; the message lists their identifiers.
        case ambiguousProcessName
        /// Injection or the handshake after it failed.
        case attachFailed
        /// The host is shutting down and no longer takes commands.
        case hostBusy
        case unsupportedProtocolVersion
        case cancelled
        case internalError
    }

    public let code: Code
    public let message: String

    public init(code: Code, message: String) {
        self.code = code
        self.message = message
    }

    /// Passes a `CommandFailure` through and folds anything else into a code.
    public static func wrapping(_ error: any Error) -> CommandFailure {
        if let failure = error as? CommandFailure {
            return failure
        }
        if error is CancellationError {
            return CommandFailure(code: .cancelled, message: "The command was cancelled.")
        }
        return CommandFailure(code: .internalError, message: error.localizedDescription)
    }
}

extension CommandFailure: LocalizedError, CustomStringConvertible {
    public var errorDescription: String? { description }

    public var description: String {
        "\(message) [\(code.rawValue)]"
    }
}

/// Progress the host reports while a long command runs (`export`, `attach`).
public struct CommandProgress: Codable, Sendable, Hashable {
    public let phase: String
    public let current: Int?
    public let total: Int?
    public let detail: String?

    public init(phase: String, current: Int? = nil, total: Int? = nil, detail: String? = nil) {
        self.phase = phase
        self.current = current
        self.total = total
        self.detail = detail
    }
}
