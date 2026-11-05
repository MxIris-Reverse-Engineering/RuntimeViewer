import Foundation
import FoundationToolbox
import Semaphore

/// Errors that can occur during message channel operations.
enum RuntimeMessageChannelError: Error, LocalizedError, Sendable {
    case notConnected
    case receiveFailed
    case requestTimeout

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Message channel is not connected"
        case .receiveFailed:
            return "Failed to receive message"
        case .requestTimeout:
            return "Request timed out before a response arrived"
        }
    }
}
