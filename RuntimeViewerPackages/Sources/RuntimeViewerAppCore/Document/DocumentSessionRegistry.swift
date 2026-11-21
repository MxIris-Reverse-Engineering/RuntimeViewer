import Foundation
import Dependencies
import DependenciesMacros
import RuntimeViewerCore

/// The document session of each window a scene-based front end shows — the
/// iOS-family apps, one ``DocumentSession`` per `UIScene` — by the window's
/// identifier, a `UISceneSession.persistentIdentifier`.
///
/// A window keeps its session while the process lives, so a window the
/// system disconnects to save memory and connects again finds its session —
/// and the file it shows — as it left them. The session closes only when the
/// user closes the window (``discardSessions(forWindows:)``).
///
/// A window opened for a particular engine — a file the user opened — is
/// requested with the engine reserved under a request identifier, which the
/// new window hands back as it connects. A window whose request is unknown —
/// one the system restores after a relaunch — starts on this device.
@MainActor
public final class DocumentSessionRegistry {
    fileprivate static let shared = DocumentSessionRegistry()

    private var sessionsByWindowIdentifier: [String: DocumentSession] = [:]

    private var reservedEnginesByRequestIdentifier: [UUID: RuntimeEngine] = [:]

    private let makeDefaultRuntimeEngine: @MainActor () -> RuntimeEngine

    /// - Parameter makeDefaultRuntimeEngine: The engine of a window nobody
    ///   reserved one for. Test seam.
    init(makeDefaultRuntimeEngine: @escaping @MainActor () -> RuntimeEngine = { .local }) {
        self.makeDefaultRuntimeEngine = makeDefaultRuntimeEngine
    }

    /// Holds `runtimeEngine` for a window about to be requested, and names
    /// the request: hand the identifier to the new window, which passes it
    /// to ``session(forWindow:requestIdentifier:)``.
    public func reserveWindow(on runtimeEngine: RuntimeEngine) -> UUID {
        let requestIdentifier = UUID()
        reservedEnginesByRequestIdentifier[requestIdentifier] = runtimeEngine
        return requestIdentifier
    }

    /// Lets go of an engine reserved for a window that will not come, because
    /// the request for it failed.
    public func cancelReservation(_ requestIdentifier: UUID) {
        reservedEnginesByRequestIdentifier.removeValue(forKey: requestIdentifier)
    }

    /// The session of the window `windowIdentifier`: the one it already has,
    /// or a new one on the engine reserved under `requestIdentifier`, or on
    /// this device when nothing is reserved under it. A new session is not
    /// opened yet: open it before the window's UI binds.
    public func session(forWindow windowIdentifier: String, requestIdentifier: UUID?) -> DocumentSession {
        if let session = sessionsByWindowIdentifier[windowIdentifier] {
            return session
        }
        let reservedEngine = requestIdentifier.flatMap { reservedEnginesByRequestIdentifier.removeValue(forKey: $0) }
        let session = DocumentSession(runtimeEngine: reservedEngine ?? makeDefaultRuntimeEngine())
        sessionsByWindowIdentifier[windowIdentifier] = session
        return session
    }

    /// Closes and forgets the sessions of the windows the user closed.
    public func discardSessions(forWindows windowIdentifiers: some Sequence<String>) {
        for windowIdentifier in windowIdentifiers {
            sessionsByWindowIdentifier.removeValue(forKey: windowIdentifier)?.close()
        }
    }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { DocumentSessionRegistry.shared })
    public var documentSessionRegistry: DocumentSessionRegistry
}
