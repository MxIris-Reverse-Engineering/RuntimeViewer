import Foundation

/// Wire envelope for `RuntimeEngineProgressCommand` round trips. See the
/// protocol's "Wire form" note.
struct RuntimeEngineProgressEnvelope<Command: Codable & Sendable>: Codable, Sendable {
    /// Routing key the serving peer must echo on every progress push for this
    /// round trip; `nil` disables progress reporting.
    let progressToken: String?

    /// The command itself. **Named `request` on purpose**: this is a `Codable`
    /// stored property, so its name is a JSON key that peers built before the
    /// `Request` → `Command` rename still encode and decode. Renaming it would
    /// change the wire format, which the rename deliberately did not.
    let request: Command

    /// Names this round trip for `CommandName.cancelRequest`. Set only for
    /// command types that cancel across connections; `nil` — and then absent
    /// from the encoding — for every other, so a peer that predates it is
    /// never sent the key. A peer that predates it skips the key anyway, and
    /// one that receives no key serves the request as it always did.
    let requestIdentifier: String?
}
