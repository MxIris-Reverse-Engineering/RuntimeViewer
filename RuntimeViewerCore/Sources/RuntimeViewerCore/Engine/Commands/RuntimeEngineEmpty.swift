import Foundation

/// Fire-and-forget marker so that `Void`-returning commands can ride the same
/// `RuntimeEngineCommand` machinery as response-bearing ones. Encodes as `{}`.
public struct RuntimeEngineEmpty: Codable, Sendable {
    public init() {}
}
