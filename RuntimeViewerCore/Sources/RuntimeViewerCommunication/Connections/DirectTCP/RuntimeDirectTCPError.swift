#if canImport(Network)

import Foundation
import FoundationToolbox
import Network
import Combine

/// Errors that can occur during direct TCP operations.
enum RuntimeDirectTCPError: Error, LocalizedError {
    case connectionFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to establish connection"
        case .timeout:
            return "Connection timed out"
        }
    }
}

#endif
