import Foundation
import RuntimeViewerCommunication

extension RuntimeRemoteEngineDescriptor {
    /// The scope a mirror of this engine files its bookmarks and sidebar state
    /// under.
    ///
    /// A mirror connects over a proxy whose `directTCP` host and port are
    /// assigned per session, so deriving a scope from the *mirror's* own source
    /// would produce a key that changes on every reconnect. The identity has to
    /// come from the peer that owns the engine, which is why it travels on the
    /// descriptor — as an opaque `stableIdentity` string that the communication
    /// layer forwards without interpreting. This is the one place that reads it
    /// back as a scope.
    public var bookmarkScope: RuntimeBookmarkScope {
        if let identity = RuntimeBookmarkScope.Identity(rawValue: stableIdentity) {
            return .identified(identity)
        }
        // Either the peer predates the field, or it sent something this version
        // cannot parse. Both land here, and both recover from `source` — the
        // descriptor's own, describing the mirrored engine, never the proxy.
        return RuntimeBookmarkScope.recovered(from: source) ?? .legacy(for: source)
    }
}
