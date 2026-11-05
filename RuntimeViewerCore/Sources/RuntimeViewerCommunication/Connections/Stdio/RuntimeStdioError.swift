import Foundation
import FoundationToolbox
import Combine

/// Errors that can occur during stdio communication.
enum RuntimeStdioError: Error, LocalizedError, Sendable {
    /// The connection is not established or has been closed.
    case notConnected
    /// Failed to receive data from the input stream.
    case receiveFailed

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Stdio connection is not established"
        case .receiveFailed:
            return "Failed to receive data from stdio"
        }
    }
}
