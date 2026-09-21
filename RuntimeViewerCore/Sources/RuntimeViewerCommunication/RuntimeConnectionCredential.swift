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
/// | `.local` run in the XPC service | `.xpcService(target)`     | Required to get a connection at all; without it `.local` has none |
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

    /// The embedded XPC service a `.local` engine forwards its work to.
    ///
    /// `.local` names this Mac, not a transport, so on its own it yields no connection. This is
    /// the one thing that gives it one: which service to reach (the app's, by bundle identifier,
    /// or an anonymous listener in a test). It is a credential rather than part of the source
    /// for the same reason the Bonjour endpoint is — the engine's identity, and everything keyed
    /// on it, must not change because its work moved to another process.
    case xpcService(RuntimeXPCServiceTarget)
    #endif
}
