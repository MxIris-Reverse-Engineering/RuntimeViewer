import Foundation

/// A single progress event pushed back to the requester on the shared
/// `progressEvent` channel.
struct RuntimeEngineProgressPush: Codable, Sendable {
    let token: String
    /// JSON-encoded `Progress` value. Kept as raw `Data` so the push handler
    /// stays untyped; the requester's routing table decodes it with the
    /// concrete type captured at `dispatch(_:onProgress:)` time.
    let payload: Data
}
