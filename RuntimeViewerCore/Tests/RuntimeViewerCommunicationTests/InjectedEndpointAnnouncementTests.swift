#if os(macOS)
import Testing
import Foundation
@testable import RuntimeViewerCommunication

/// Covers which XPC servers announce themselves to the injected-endpoint
/// registry.
///
/// The registry means "an injected app the host cannot relaunch"; the host's
/// reconnect pass treats every entry as one. The Mac Catalyst helper
/// announcing itself is the reproduction: the reconnect pass runs in the same
/// launch, right after the helper connects, fetched the helper's endpoint,
/// opened a direct connection, and its `ClientReconnected` handling swapped
/// the helper's single peer slot away from the just-built
/// "My Mac (Mac Catalyst)" engine — leaving an attached
/// "RuntimeViewerCatalystHelper" entry in its place. A clean quit and relaunch
/// reproduced it; no orphaned process is involved.
@Suite("Injected endpoint announcement")
struct InjectedEndpointAnnouncementTests {
    /// The ghost-entry reproduction: the helper must stay out of the registry.
    @Test("The Mac Catalyst helper does not announce itself")
    func macCatalystHelperDoesNotAnnounce() {
        #expect(!RuntimeXPCServerConnection.shouldAnnounceListenerEndpoint(identifier: .macCatalyst))
    }

    /// Injected apps are what the registry exists for: their identifier is the
    /// target's pid, and they must keep announcing or the host loses the
    /// ability to reconnect to them after a restart.
    @Test("Injected servers keep announcing")
    func injectedServersKeepAnnouncing() {
        #expect(RuntimeXPCServerConnection.shouldAnnounceListenerEndpoint(identifier: .init(rawValue: "42475")))
    }

    /// The identifier is shared vocabulary between the app (client side) and
    /// the helper (server side); it moved from RuntimeViewerCatalystExtensions
    /// into the communication layer so the announcement decision can key on
    /// it. Pin the raw value so the move cannot silently change the identity
    /// the two sides rendezvous on.
    @Test("The Mac Catalyst identifier's raw value is stable")
    func macCatalystIdentifierRawValueIsStable() {
        #expect(RuntimeSource.Identifier.macCatalyst.rawValue == "com.RuntimeViewer.RuntimeSource.MacCatalyst")
    }
}
#endif
