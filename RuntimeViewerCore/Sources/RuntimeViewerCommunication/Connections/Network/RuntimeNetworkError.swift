import Foundation

public enum RuntimeNetworkError: Error {
    case notConnected
    case invalidPort
    case receiveFailed
}
