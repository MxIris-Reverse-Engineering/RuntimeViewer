import Foundation
import FoundationToolbox

/// The message handlers a connection has been given, kept so that every
/// transport connection it runs on gets all of them before it receives
/// anything.
///
/// A server connection takes a new transport connection for every client it
/// accepts, and a reconnecting client one for every reconnect; a handler set
/// only on the transport connection of the moment is gone with it. The engine
/// registers its handlers once and registers them again only after it has seen
/// `.connected` — too late for a request the peer sends the moment it is in,
/// which then finds no handler and reads to the peer like a command an older
/// build does not know.
///
/// One handler per message name, as on the transport connection itself: a
/// server engine registers its handlers again each time a client reconnects,
/// and those replace the ones kept before instead of piling up.
///
/// `@unchecked Sendable`: the one stored property is a `Mutex`.
final class RuntimeMessageHandlerReplay<Connection: RuntimeUnderlyingConnection>: @unchecked Sendable {
    private let setupsByName = Mutex<[String: @Sendable (Connection) -> Void]>([:])

    /// Keeps `setup`, which sets the handler for the message `name`, for
    /// every later transport connection, and runs it on `currentConnection`
    /// now.
    func record(name: String, applyingTo currentConnection: Connection?, _ setup: @escaping @Sendable (Connection) -> Void) {
        setupsByName.withLock { $0[name] = setup }
        if let currentConnection {
            setup(currentConnection)
        }
    }

    /// Runs every handler kept so far on `connection`. Call it before the
    /// connection starts receiving. The handlers run outside the lock.
    func apply(to connection: Connection) {
        let snapshot = setupsByName.withLock { Array($0.values) }
        for setup in snapshot {
            setup(connection)
        }
    }
}
