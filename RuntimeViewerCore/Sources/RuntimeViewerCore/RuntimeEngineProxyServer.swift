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

@Loggable(.private)
public actor RuntimeEngineProxyServer {
    /// Command name for icon requests from remote clients.
    public static let iconRequestCommand = "com.RuntimeViewer.ProxyServer.requestIcon"

    public let engine: RuntimeEngine

    private let communicator = RuntimeCommunicator()
    private var connection: RuntimeConnection?
    private var subscriptions: Set<AnyCancellable> = []
    /// Push-relay subscriptions are re-established on every `.connected`
    /// transition (each new/reconnecting client). They live in their own set so
    /// `setupPushRelay()` can drop the previous client's relays before wiring
    /// new ones — otherwise each reconnect would stack another relay and every
    /// data change would be sent N times.
    private var pushRelaySubscriptions: Set<AnyCancellable> = []
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
        connection = try await communicator.connect(to: source, waitForConnection: false)
        if let info = connection?.connectionInfo {
            host = info.host
            port = info.port
        }
        let proxyHost = self.host
        let proxyPort = self.port
        #log(.info, "[PROXY \(self.identifier, privacy: .public)] listening on \(proxyHost, privacy: .public):\(proxyPort, privacy: .public)")

        let id = self.identifier
        connection?.statePublisher
            .sink { [weak self] state in
                guard let self else { return }
                #log(.info, "[PROXY \(id, privacy: .public)] connection state: \(String(describing: state), privacy: .public)")
                if state == .connected {
                    Task {
                        #log(.info, "[PROXY \(id, privacy: .public)] client connected, setting up handlers...")
                        await self.setupRequestHandlers()
                        #log(.info, "[PROXY \(id, privacy: .public)] request handlers registered")
                        await self.setupPushRelay()
                        #log(.info, "[PROXY \(id, privacy: .public)] push relay set up, sending initial data...")
                        await self.sendInitialData()
                        #log(.info, "[PROXY \(id, privacy: .public)] initial data sent")
                    }
                }
            }
            .store(in: &subscriptions)
    }

    private func sendInitialData() async {
        guard let connection else {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] sendInitialData: connection is nil!")
            return
        }
        let imageList = await engine.imageList
        let imageNodes = engine.imageNodes
        #log(.info, "[PROXY \(self.identifier, privacy: .public)] sendInitialData: imageList=\(imageList.count, privacy: .public), imageNodes=\(imageNodes.count, privacy: .public)")
        do {
            try await connection.sendMessage(
                name: RuntimeEngine.CommandNames.imageList.commandName,
                request: imageList
            )
            #log(.info, "[PROXY \(self.identifier, privacy: .public)] sent imageList OK")
        } catch {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] failed to send imageList: \(error, privacy: .public)")
        }
        do {
            try await connection.sendMessage(
                name: RuntimeEngine.CommandNames.imageNodes.commandName,
                request: imageNodes
            )
            #log(.info, "[PROXY \(self.identifier, privacy: .public)] sent imageNodes OK")
        } catch {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] failed to send imageNodes: \(error, privacy: .public)")
        }
        do {
            try await connection.sendMessage(
                name: RuntimeEngine.CommandNames.dataDidChange.commandName,
                request: RuntimeDataChange.fullReload(isReloadImageNodes: true)
            )
            #log(.info, "[PROXY \(self.identifier, privacy: .public)] sent dataDidChange(fullReload) OK")
        } catch {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] failed to send dataDidChange: \(error, privacy: .public)")
        }
    }

    public func stop() {
        #log(.info, "[PROXY \(self.identifier, privacy: .public)] stopping")
        connection?.stop()
        subscriptions.removeAll()
        pushRelaySubscriptions.removeAll()
    }

    // MARK: - Request Handlers

    private func setupRequestHandlers() {
        guard let connection else {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] setupRequestHandlers: connection is nil!")
            return
        }

        // Shared registry — same set of commands `RuntimeEngine`'s own server
        // arm installs. Adding a new shared command in
        // `RuntimeEngine.registerSharedHandlers(on:engine:)` automatically
        // takes effect here too, eliminating the parallel-edit hazard that
        // used to bite us every time a new command landed. Progress-bearing
        // commands need no proxy-specific code either: `registerProgress`
        // relays their progress pushes back to the requesting peer, including
        // across chained client engines (e.g. the Mac Catalyst helper).
        RuntimeEngine.registerSharedHandlers(on: connection, engine: engine)

        #if canImport(AppKit)
        // Proxy-only: serve the running app icon to whichever client connects.
        let engineSource = engine.source
        connection.setMessageHandler(name: Self.iconRequestCommand) {
            () -> Data? in
            let wrapper = await MainActor.run {
                SendableImage(image: Self.fetchAppIcon(for: engineSource))
            }
            return Self.encodeIconToPNG(wrapper.image)
        }
        #endif

        #log(.info, "[PROXY \(self.identifier, privacy: .public)] all handlers registered")
    }

    // MARK: - Icon

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

    // MARK: - Push Relay

    private func setupPushRelay() {
        guard let connection else {
            #log(.error, "[PROXY \(self.identifier, privacy: .public)] setupPushRelay: connection is nil!")
            return
        }

        // Drop the previous client's relays before wiring new ones, so a
        // reconnect doesn't stack duplicate subscriptions (which would resend
        // every change once per past connection).
        pushRelaySubscriptions.removeAll()

        let id = self.identifier
        engine.imageNodesPublisher
            .dropFirst()
            .sink { imageNodes in
                #log(.info, "[PROXY \(id, privacy: .public)] relaying imageNodes (\(imageNodes.count, privacy: .public) nodes)")
                Task {
                    try? await connection.sendMessage(
                        name: RuntimeEngine.CommandNames.imageNodes.commandName,
                        request: imageNodes
                    )
                }
            }
            .store(in: &pushRelaySubscriptions)

        engine.dataChangePublisher
            .sink { [weak self] change in
                guard let self else { return }
                #log(.info, "[PROXY \(id, privacy: .public)] relaying dataChange \(String(describing: change), privacy: .public)")
                Task {
                    // Keep the client's `imageList` mirror current on full reloads;
                    // other change kinds don't affect it so we skip the extra round-trip.
                    if case .fullReload = change {
                        let imageList = await self.engine.imageList
                        try? await connection.sendMessage(
                            name: RuntimeEngine.CommandNames.imageList.commandName,
                            request: imageList
                        )
                    }
                    try? await connection.sendMessage(
                        name: RuntimeEngine.CommandNames.dataDidChange.commandName,
                        request: change
                    )
                }
            }
            .store(in: &pushRelaySubscriptions)
    }
}

#endif
