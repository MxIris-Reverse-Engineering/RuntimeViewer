#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication

/// The engine the app actually runs "My Mac" on: a `.local` engine forwarding
/// to the local service, here an anonymous listener in this process.
/// A request sent over it runs in the serving engine and its progress comes
/// back as pushes; the in-process engine most suites use takes none of the
/// paths a connection takes.
struct LocalServiceFixture {
    let client: RuntimeEngine
    let serving: RuntimeEngine
    let host: RuntimeLocalServiceHost

    static func make(label: String) async throws -> LocalServiceFixture {
        let serving = RuntimeEngine(source: .local, engineID: "\(label).serving")
        let (listener, endpoint) = try RuntimeXPCServiceListenerConnection.anonymous()
        let host = RuntimeLocalServiceHost(engine: serving, connection: listener)
        try await host.start()
        host.activate()
        let client = RuntimeEngine(source: .local, engineID: "\(label).client")
        try await client.connect(credential: .xpcService(.anonymousListener(endpoint)))
        return LocalServiceFixture(client: client, serving: serving, host: host)
    }

    func stop() async {
        await client.stop()
        await host.stop()
    }
}

#endif
