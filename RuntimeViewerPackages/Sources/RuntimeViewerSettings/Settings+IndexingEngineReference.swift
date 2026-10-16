import Foundation
import RuntimeViewerCore

extension Settings.Indexing.EngineReference {
    /// A reference to `engine`, under the names it carries now.
    public init(engine: RuntimeEngine) {
        self.init(
            key: Self.key(for: engine),
            name: engine.source.description,
            hostName: engine.hostInfo.hostName
        )
    }

    /// The key an always-index entry matches `engine` by.
    ///
    /// The engine's bookmark scope wherever that scope survives the peer
    /// relaunching, which is everywhere but a process attached on this Mac:
    /// its scope carries the process identifier, so a key built from it would
    /// stop matching the next time the process is launched, and the entry
    /// would keep a reference no engine can ever answer to again. Such a
    /// process is matched by its name instead, so every process of that name
    /// shares the choice. Bookmarks must never be keyed that way, since two
    /// same-named processes may not share their bookmarks; a filter the user
    /// writes wants exactly that.
    ///
    /// The two kinds of key carry different prefixes, so a process name can
    /// never pass for a scope.
    public static func key(for engine: RuntimeEngine) -> String {
        if case .identified(let identity) = engine.bookmarkScope, identity.carriesProcessIdentifier {
            return processKeyPrefix + engine.source.description
        }
        return scopeKeyPrefix + engine.bookmarkScope.bookmarkKey
    }

    private static let scopeKeyPrefix = "scope:"

    private static let processKeyPrefix = "process:"
}

extension RuntimeBookmarkScope.Identity {
    /// Whether the identity is a process identifier, which changes every time
    /// the process is launched.
    ///
    /// Only an attached process on this Mac is identified that way, over XPC
    /// or over a local socket. The other XPC identity, Mac Catalyst's, is a
    /// fixed name.
    fileprivate var carriesProcessIdentifier: Bool {
        switch self {
        case .remote(let identifier, _), .localSocket(let identifier, _):
            return Int32(identifier) != nil
        case .local, .injectedTCP, .directTCP, .bonjour:
            return false
        }
    }
}
