import Foundation

public enum RuntimeNetworkError: Error {
    case notConnected
    case invalidPort
    case receiveFailed
}

public struct RuntimeNetworkRequestError: Error, Codable {
    public let message: String
}
