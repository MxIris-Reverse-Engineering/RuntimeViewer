#if canImport(Network)

public import Foundation
import Combine
public import FoundationToolbox
import RuntimeViewerCommunication
#if canImport(AppKit)
import AppKit

/// Wraps an NSImage to cross isolation boundaries on macOS < 14 where NSImage lacks Sendable conformance.
private struct SendableImage: @unchecked Sendable {
    let image: NSImage?
}
#endif

/// Shares one engine with peers over a localhost TCP listener.
///
/// The serving itself — command table, pushes, initial data — is
/// `RuntimeEngineConnectionServer`; this type owns the TCP transport, wires
/// the server up for each client that connects, and adds the proxy-only icon
/// request.
@Loggable(.private)
public actor RuntimeEngineProxyServer {
    /// Command name for icon requests from remote clients.
    public static let iconRequestCommand = "com.RuntimeViewer.ProxyServer.requestIcon"

    public let engine: RuntimeEngine

    private let communicator = RuntimeCommunicator()
    private var connection: (any RuntimeConnection)?
    private var server: RuntimeEngineConnectionServer?
    private var subscriptions: Set<AnyCancellable> = []
    private let identifier: String

    public private(set) var port: UInt16 = 0
    public private(set) var host: String = ""

    public init(engine: RuntimeEngine, identifier: String) {
        self.engine = engine
        self.identifier = identifier
    }

    public func start() async throws {
        let source = RuntimeSource.directTCP(
            name: identifier,
            host: nil,
            port: 0,
            role: .server
        )
        #log(.info, "[PROXY \(self.identifier, privacy: .public)] starting...")
        let connection = try await communicator.connect(to: source, waitForConnection: false)
        self.connection = connection
        if let info = connection.connectionInfo {
            host = info.host
            port = info.port
        }
        let proxyHost = self.host
        let proxyPort = self.port
        #log(.info, "[PROXY \(self.identifier, privacy: .public)] listening on \(proxyHost, privacy: .public):\(proxyPort, privacy: .public)")

        let server = RuntimeEngineConnectionServer(engine: engine, connection: connection, label: "PROXY \(identifier)")
        self.server = server

        let id = self.identifier
        connection.statePublisher
            .sink { [weak self] state in
                guard let self else { return }
                #log(.info, "[PROXY \(id, privacy: .public)] connection state: \(String(describing: state), privacy: .public)")
                if state == .connected {
                    Task {
                        #log(.info, "[PROXY \(id, privacy: .public)] client connected, setting up handlers...")
                        await server.registerRequestHandlers()
                        await self.registerIconHandler(on: connection)
                        await server.installPushRelay()
                        #log(.info, "[PROXY \(id, privacy: .public)] push relay set up, sending initial data...")
                        await server.sendInitialData()
                        #log(.info, "[PROXY \(id, privacy: .public)] initial data sent")
                    }
                }
            }
            .store(in: &subscriptions)
    }

    public func stop() async {
        #log(.info, "[PROXY \(self.identifier, privacy: .public)] stopping")
        await server?.stop()
        server = nil
        connection?.stop()
        subscriptions.removeAll()
    }

    // MARK: - Icon

    /// Proxy-only: serve the running app icon to whichever client connects.
    private func registerIconHandler(on connection: any RuntimeConnection) {
        #if canImport(AppKit)
        let engineSource = engine.source
        connection.setMessageHandler(name: Self.iconRequestCommand) {
            () -> Data? in
            let wrapper = await MainActor.run {
                SendableImage(image: Self.fetchAppIcon(for: engineSource))
            }
            return Self.encodeIconToPNG(wrapper.image)
        }
        #endif
    }

    /// Returns the app icon PNG data for this engine's attached process, or nil.
    public func iconData() async -> Data? {
        #if canImport(AppKit)
        let wrapper = await MainActor.run {
            SendableImage(image: Self.fetchAppIcon(for: engine.source))
        }
        return Self.encodeIconToPNG(wrapper.image)
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    /// Fetches the app icon image for the given source. Must be called on the main thread.
    @MainActor
    private static func fetchAppIcon(for source: RuntimeSource) -> NSImage? {
        let pidString: String?
        switch source {
        case .remote(_, let identifier, _):
            pidString = identifier.rawValue
        case .localSocket(_, let identifier, _):
            pidString = identifier.rawValue
        default:
            pidString = nil
        }
        guard let pidString, let pid = Int32(pidString) else { return nil }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.icon ?? app.bundleURL.flatMap { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Encodes an NSImage to PNG data. Safe to call from any thread.
    private static func encodeIconToPNG(_ icon: NSImage?) -> Data? {
        guard let icon else { return nil }
        return icon.tiffRepresentation.flatMap {
            NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:])
        }
    }
    #endif
}

#endif
