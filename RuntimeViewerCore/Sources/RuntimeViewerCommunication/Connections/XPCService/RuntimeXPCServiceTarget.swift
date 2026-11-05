#if os(macOS)

public import Foundation
import FoundationToolbox
import Combine
import SwiftyXPC
import HelperCommunication

/// Where an XPC-service client connects to.
///
/// An embedded XPC service is reached by bundle identifier: launchd looks it
/// up in the calling process's own bundle, which is why only the app itself
/// can reach the one it ships. The anonymous-listener case exists for tests,
/// where both ends of a `RuntimeXPCServiceClientConnection` /
/// `RuntimeXPCServiceListenerConnection` pair live in one `xctest` process.
public enum RuntimeXPCServiceTarget: Sendable {
    /// The embedded service with this bundle identifier, launched on demand
    /// by launchd from the calling process's bundle.
    case bundleIdentifier(String)

    /// A process of its own for this connection: launchd starts a new
    /// instance of the embedded service, which declares `_MultipleInstances`
    /// in its `Info.plist`, and the connection's first `hello` hands the
    /// instance `launchPayload` — what it has to know before it can serve,
    /// such as the file an offline engine reads. An instance that went away
    /// is never relaunched, so reattaching starts another one, with the same
    /// payload, behind a new connection.
    case dedicatedInstance(bundleIdentifier: String, launchPayload: Data)

    /// An anonymous listener some process opened and handed over its endpoint.
    case anonymousListener(RuntimeXPCServiceEndpoint)
}

#endif
