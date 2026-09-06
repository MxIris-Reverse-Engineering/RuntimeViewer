#if os(macOS)
import RuntimeViewerCore
import RuntimeViewerCommunication

/// Something a ``RuntimeEngineManager`` wants the layer above it to know about.
///
/// The manager used to call the app's notification service directly. Emitting
/// events instead keeps `UNUserNotificationCenter` — which needs an app bundle
/// to exist at all — out of a module a windowless process links.
public enum RuntimeEngineManagerEvent: Sendable {
    /// An engine the manager observes reported `.connected`. Fired for every
    /// observed engine, including reconnects.
    case engineConnected(RuntimeEngine)

    /// An engine disconnected and no other route to its host remains, so the
    /// host has vanished from the sections. A direct Bonjour drop while a
    /// forwarded mirror of the same peer survives does *not* fire this.
    case hostDisconnected(source: RuntimeSource, error: (any Error)?)

    /// The Mac Catalyst client engine or its helper application could not be
    /// brought up. `.local` and injected-process reconnection are unaffected.
    case catalystHelperUnavailable(any Error)
}
#endif
