import Foundation

/// The envelope every request and response travels in.
///
/// Sits beside `RuntimeMessageChannel`, its only user, rather than under
/// `Network/`: the channel carries these over whichever transport it was handed,
/// not only over the network.
struct RuntimeRequestData: Codable {
    let identifier: String

    let data: Data

    /// Per-round-trip routing key. `nil` for fire-and-forget messages and
    /// for messages that originated on a peer that doesn't stamp one
    /// (wire-level backward compat). When non-nil, `sendRequest<Response>`
    /// uses it to key the `pendingRequests` entry — multiple concurrent
    /// in-flight requests can therefore share the same `identifier`
    /// (command name) without colliding on the pending-routing table, so
    /// the channel's `sendSemaphore` no longer has to serialize round
    /// trips end-to-end. Peer-side handlers must echo the value verbatim
    /// in the response envelope; without it the client falls back to
    /// `identifier` (legacy behavior, single in-flight per command).
    let nonce: String?

    /// Marks a response envelope whose `data` carries a
    /// `RuntimeNetworkRequestError` instead of the expected `Response`. Set on
    /// every error reply (the handler threw, or no handler was registered) so
    /// `sendRequest` can surface the remote failure as a real error rather than
    /// an opaque `DecodingError` (or — worse — a bogus all-optional "success").
    /// Optional for wire backward-compat: an absent key decodes to `nil`, which
    /// is treated as "not an error", matching legacy peers that never set it.
    let isError: Bool?

    init(identifier: String, data: Data, nonce: String? = nil, isError: Bool? = nil) {
        self.identifier = identifier
        self.data = data
        self.nonce = nonce
        self.isError = isError
    }

    init<Value: Codable>(identifier: String, value: Value, nonce: String? = nil) throws {
        self.identifier = identifier
        self.data = try JSONEncoder().encode(value)
        self.nonce = nonce
        self.isError = nil
    }

    init<Request: RuntimeRequest>(request: Request, nonce: String? = nil) throws {
        self.identifier = Request.identifier
        self.data = try JSONEncoder().encode(request)
        self.nonce = nonce
        self.isError = nil
    }
}
