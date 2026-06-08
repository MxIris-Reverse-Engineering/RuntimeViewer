import Foundation

#if os(macOS)
public import HelperCommunication
#endif

/// Session-scoped credential required by some `RuntimeSource` cases at connect time.
///
/// `RuntimeSource` describes the **identity** of a connection target (stable, `Codable`, used for
/// equality / hashing / persistence). A credential is the orthogonal piece of information that is
/// resolved per session — typically by service discovery or a prior handshake — and therefore must
/// not participate in the source's identity.
///
/// The cases are mutually exclusive: a single `connect(to:credential:)` call needs at most one of
/// them, so they collapse into a single optional parameter instead of separate slots.
///
/// ## When to provide a credential
///
/// | Source                          | Credential                | Required? |
/// |---------------------------------|---------------------------|-----------|
/// | `.bonjour` + `.client`          | `.bonjour(endpoint)`      | Required  |
/// | `.remote` + `.client` (reconnect) | `.xpcServer(endpoint)` | Optional, enables direct reconnect |
/// | All other cases                 | `nil`                     | —         |
public enum RuntimeConnectionCredential: Sendable {
    /// Bonjour endpoint resolved by service discovery.
    ///
    /// Required for `RuntimeSource.bonjour` with `Role.client` — the endpoint cannot be
    /// derived from the source alone because it is produced at runtime by `NWBrowser`.
    case bonjour(RuntimeNetworkEndpoint)

    #if os(macOS)
    /// XPC server endpoint captured from a prior handshake.
    ///
    /// Optional for `RuntimeSource.remote` with `Role.client`. When supplied, the communicator
    /// reconnects directly to the existing peer instead of going through XPC service lookup —
    /// used for reattaching to previously-injected processes.
    case xpcServer(HelperPeerEndpoint)
    #endif
}
