#if os(macOS)
import AppKit
import Foundation
import FoundationToolbox
import OrderedCollections
import ServiceManagement
import SystemConfiguration
import Dependencies
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerArchitectures
import RuntimeViewerHelperClient
import RuntimeViewerCatalystExtensions

@Loggable
@MainActor
public final class RuntimeEngineManager {
    public static let shared = RuntimeEngineManager()

    // MARK: - Published State

    @Published
    public private(set) var systemRuntimeEngines: [RuntimeEngine] = []

    @Published
    public private(set) var attachedRuntimeEngines: [RuntimeEngine] = []

    @Published
    public private(set) var bonjourRuntimeEngines: [RuntimeEngine] = []

    @Published
    public private(set) var mirroredEngines: OrderedDictionary<String, RuntimeEngine> = [:]

    @Published
    public private(set) var runtimeEngineSections: [RuntimeEngineSection] = []

    // MARK: - Private State

    private let browser = RuntimeNetworkBrowser()

    private var knownBonjourEndpointNames: Set<String> = []

    /// Endpoints that were rediscovered while a stale engine with the same name
    /// was still being torn down. After `terminateRuntimeEngine` clears the name,
    /// we re-issue `connectToBonjourEndpoint` for any pending entry so the user
    /// gets auto-reconnected (e.g. when the iOS server resumes from background
    /// suspension and re-advertises Bonjour before the old NWConnection has
    /// timed out on this side).
    private var pendingReconnectEndpoints: [String: RuntimeNetworkEndpoint] = [:]

    private static let maxRetryAttempts = 3

    private static let retryBaseDelay: UInt64 = 2_000_000_000 // 2 seconds in nanoseconds

    private var bonjourServerEngine: RuntimeEngine?

    private var proxyServers: [String: RuntimeEngineProxyServer] = [:]

    /// Cache for engine icons keyed by engine ID.
    private var engineIconCache: [String: NSImage] = [:]

    /// Bonjour client engines whose remotes don't support engine sharing
    /// (returned 0 descriptors). These are shown directly in the Toolbar
    /// instead of being hidden as management-only connections.
    private var directBonjourEngines: Set<ObjectIdentifier> = []

    // MARK: - Dependencies

    @Dependency(\.helperServiceManager)
    private var helperServiceManager

    @Dependency(\.runtimeConnectionNotificationService)
    private var runtimeConnectionNotificationService

    @Dependency(\.runtimeHelperClient)
    private var runtimeHelperClient

    @Dependency(\.runtimeInjectClient)
    private var runtimeInjectClient

    // MARK: - Socket Injection Persistence

    private struct InjectedSocketEndpointRecord: Codable {
        let pid: pid_t
        let appName: String
    }

    private static var injectedSocketEndpointsFileURL: URL {
        let applicationSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let runtimeViewerDirectory = applicationSupportURL.appendingPathComponent("RuntimeViewer")
        try? FileManager.default.createDirectory(at: runtimeViewerDirectory, withIntermediateDirectories: true)
        return runtimeViewerDirectory.appendingPathComponent("injected-socket-endpoints.json")
    }

    private func loadInjectedSocketEndpointRecords() -> [InjectedSocketEndpointRecord] {
        let fileURL = Self.injectedSocketEndpointsFileURL
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([InjectedSocketEndpointRecord].self, from: data)) ?? []
    }

    private func saveInjectedSocketEndpointRecords(_ records: [InjectedSocketEndpointRecord]) {
        let fileURL = Self.injectedSocketEndpointsFileURL
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }

    private func addInjectedSocketEndpointRecord(pid: pid_t, appName: String) {
        var records = loadInjectedSocketEndpointRecords()
        records.removeAll { $0.pid == pid }
        records.append(InjectedSocketEndpointRecord(pid: pid, appName: appName))
        saveInjectedSocketEndpointRecords(records)
    }

    private func removeInjectedSocketEndpointRecord(pid: pid_t) {
        var records = loadInjectedSocketEndpointRecords()
        records.removeAll { $0.pid == pid }
        saveInjectedSocketEndpointRecords(records)
    }

    // MARK: - Initialization

    private init() {
        #log(.info,"RuntimeEngineManager initializing, local instance ID: \(RuntimeNetworkBonjour.localInstanceID, privacy: .public)")

        // Start Bonjour server BEFORE browser so the local service's TXT record
        // (containing localInstanceID) is registered with the Bonjour daemon
        // by the time the browser discovers it.
        startBonjourServer()

        browser.start(
            onAdded: { [weak self] endpoint in
                guard let self else { return }
                if endpoint.instanceID == RuntimeNetworkBonjour.localInstanceID {
                    #log(.info,"Skipping self Bonjour endpoint: \(endpoint.name, privacy: .public), instanceID: \(endpoint.instanceID ?? "nil", privacy: .public)")
                    return
                }
                #log(.info,"Bonjour endpoint discovered: \(endpoint.name, privacy: .public), instanceID: \(endpoint.instanceID ?? "nil", privacy: .public), attempting connection...")
                Task { @MainActor in
                    await self.connectToBonjourEndpoint(endpoint)
                }
            },
            onRemoved: { [weak self] endpoint in
                guard let self else { return }
                #log(.info,"Bonjour endpoint removed: \(endpoint.name, privacy: .public)")
                // Do NOT clear knownBonjourEndpointNames here. The Bonjour service
                // is de-registered whenever the NWListener is cancelled (e.g., after
                // accepting a connection), causing the endpoint to flap. Clearing
                // the name here would allow a duplicate connection when the endpoint
                // reappears. Instead, rely on terminateRuntimeEngine (called on
                // actual disconnect) to clear the name and allow reconnection.
                _ = self
            }
        )

        Task { @MainActor in
            do {
                #log(.info,"Launching system runtime engines...")
                try await self.launchSystemRuntimeEngines()
                #log(.info,"System runtime engines launched successfully")
            } catch {
                #log(.error,"Failed to launch system runtime engines with error: \(error, privacy: .public)")
            }
        }

        startSharingEngines()
    }

    private func startBonjourServer() {
        let name = SCDynamicStoreCopyComputerName(nil, nil) as? String ?? ProcessInfo.processInfo.hostName
        let source = RuntimeSource.bonjour(name: name, identifier: .init(rawValue: name), role: .server)
        let engine = RuntimeEngine(source: source, pushesRuntimeData: false)
        bonjourServerEngine = engine

        #log(.info,"Starting Bonjour server with name: \(name, privacy: .public)")

        Task { @MainActor in
            do {
                try await engine.connect()
                #log(.info,"Bonjour server connected with name: \(name, privacy: .public)")
            } catch {
                #log(.error,"Failed to start Bonjour server: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Bonjour Connection

    private func connectToBonjourEndpoint(_ endpoint: RuntimeNetworkEndpoint, attempt: Int = 0) async {
        guard !knownBonjourEndpointNames.contains(endpoint.name) else {
            // The endpoint was rediscovered before the previous engine for this
            // name finished tearing down. Stash it so `terminateRuntimeEngine`
            // can pick it up and reconnect once the old engine is fully gone.
            #log(.info,"Skipping duplicate Bonjour endpoint: \(endpoint.name, privacy: .public), queueing for reconnect after current engine terminates")
            pendingReconnectEndpoints[endpoint.name] = endpoint
            return
        }
        // A fresh connection attempt for this name supersedes any pending one.
        pendingReconnectEndpoints.removeValue(forKey: endpoint.name)
        knownBonjourEndpointNames.insert(endpoint.name)

        do {
            let remoteHostInfo = HostInfo(
                hostID: endpoint.instanceID ?? endpoint.name,
                hostName: endpoint.hostName ?? endpoint.name,
                metadata: endpoint.deviceMetadata ?? .current
            )
            let runtimeEngine = RuntimeEngine(
                source: .bonjour(name: endpoint.name, identifier: .init(rawValue: endpoint.name), role: .client),
                hostInfo: remoteHostInfo,
                originChain: [endpoint.instanceID ?? endpoint.name]
            )
            try await runtimeEngine.connect(bonjourEndpoint: endpoint)
            appendBonjourRuntimeEngine(runtimeEngine)
            #log(.info,"Successfully connected to Bonjour endpoint: \(endpoint.name, privacy: .public)")

            // Request the remote peer's engine list for mirroring
            Task { @MainActor in
                do {
                    #log(.debug,"[EngineMirroring] requesting engine list from \(endpoint.name, privacy: .public)...")
                    // 5s deadline: peers without engine sharing (iOS, visionOS) or whose
                    // bonjour transport is silently dead (e.g. flaky AWDL) would otherwise
                    // hang this Task forever. On timeout we fall through to the catch block,
                    // which marks the engine as a direct bonjour entry.
                    let descriptors = try await runtimeEngine.requestEngineList(timeout: 5)
                    #log(.debug,"[EngineMirroring] received \(descriptors.count, privacy: .public) descriptors from \(endpoint.name, privacy: .public)")
                    if descriptors.isEmpty {
                        // Remote doesn't support engine sharing (e.g. iOS, injected app).
                        // Show the Bonjour engine directly in the Toolbar.
                        #log(.debug,"[EngineMirroring] remote \(endpoint.name, privacy: .public) returned 0 descriptors, marking as direct engine")
                        self.directBonjourEngines.insert(ObjectIdentifier(runtimeEngine))
                        self.rebuildSections()
                    } else {
                        self.handleEngineListChanged(descriptors, from: runtimeEngine)
                    }
                } catch {
                    #log(.error,"[EngineMirroring] Failed to request engine list: \(error, privacy: .public)")
                    // Treat as direct engine so it still appears in the UI
                    self.directBonjourEngines.insert(ObjectIdentifier(runtimeEngine))
                    self.rebuildSections()
                }
            }
        } catch {
            #log(.error,"Failed to connect to Bonjour endpoint: \(endpoint.name, privacy: .public) (attempt \(attempt + 1, privacy: .public)): \(error, privacy: .public)")

            if attempt < Self.maxRetryAttempts {
                let delay = Self.retryBaseDelay * UInt64(1 << attempt) // 2s, 4s, 8s
                #log(.info,"Retrying Bonjour connection to \(endpoint.name, privacy: .public) in \(delay / 1_000_000_000, privacy: .public)s...")
                try? await Task.sleep(nanoseconds: delay)
                knownBonjourEndpointNames.remove(endpoint.name)
                await connectToBonjourEndpoint(endpoint, attempt: attempt + 1)
            } else {
                knownBonjourEndpointNames.remove(endpoint.name)
                #log(.error,"Exhausted retry attempts for Bonjour endpoint: \(endpoint.name, privacy: .public)")
            }
        }
    }

    private func appendBonjourRuntimeEngine(_ bonjourRuntimeEngine: RuntimeEngine) {
        bonjourRuntimeEngines.append(bonjourRuntimeEngine)
        observeRuntimeEngineState(bonjourRuntimeEngine)
        rebuildSections()
    }

    // MARK: - Engine Lifecycle

    public var runtimeEngines: [RuntimeEngine] {
        systemRuntimeEngines + attachedRuntimeEngines + bonjourRuntimeEngines + mirroredEngines.values.elements
    }

    public func launchSystemRuntimeEngines() async throws {
        #log(.info,"Appending local runtime engine")
        systemRuntimeEngines.append(.local)
        rebuildSections()
        #if os(macOS)
        #log(.info,"Creating Mac Catalyst client runtime engine...")
        let macCatalystClientEngine = RuntimeEngine(source: .macCatalystClient)
        try await macCatalystClientEngine.connect()
        #log(.info,"Mac Catalyst client engine connected, launching helper...")
        try await runtimeHelperClient.launchMacCatalystHelper()
        #log(.info,"Mac Catalyst helper launched successfully")
        systemRuntimeEngines.append(macCatalystClientEngine)
        observeRuntimeEngineState(macCatalystClientEngine)
        rebuildSections()
        #endif
        await reconnectInjectedXPCEngines()
        await reconnectInjectedSocketEngines()
    }

    public func launchAttachedRuntimeEngine(name: String, identifier: String, isSandbox: Bool) async throws {
        let runtimeSource = if isSandbox {
            RuntimeSource.localSocket(name: name, identifier: .init(rawValue: identifier), role: .client)
        } else {
            RuntimeSource.remote(name: name, identifier: .init(rawValue: identifier), role: .client)
        }

        #log(.info,"Launching attached runtime engine: \(name, privacy: .public) (identifier: \(identifier, privacy: .public), sandbox: \(isSandbox, privacy: .public))")
        let runtimeEngine = RuntimeEngine(source: runtimeSource)
        try await runtimeEngine.connect()
        #log(.info,"Attached runtime engine connected: \(name, privacy: .public)")
        attachedRuntimeEngines.append(runtimeEngine)
        observeRuntimeEngineState(runtimeEngine)
        cacheLocalAppIcon(for: runtimeEngine, processIdentifier: identifier)

        if isSandbox, let pid = Int32(identifier) {
            addInjectedSocketEndpointRecord(pid: pid, appName: name)
        }
        rebuildSections()
    }

    public func terminateRuntimeEngine(for source: RuntimeSource) {
        #log(.info,"Terminating runtime engine: \(source.description, privacy: .public)")
        var pendingBonjourReconnect: RuntimeNetworkEndpoint?
        if case .bonjour(let name, _, let role) = source, role.isClient {
            knownBonjourEndpointNames.remove(name)
            // If the same endpoint was rediscovered while we were still tearing
            // down this engine (typical when the iOS server resumes from
            // background suspension), reconnect to it now.
            pendingBonjourReconnect = pendingReconnectEndpoints.removeValue(forKey: name)
        }
        if case .localSocket(_, let socketIdentifier, .client) = source, let pid = Int32(socketIdentifier.rawValue) {
            removeInjectedSocketEndpointRecord(pid: pid)
        }
        let removedEngines = runtimeEngines.filter { $0.source == source }
        for engine in removedEngines {
            engineIconCache.removeValue(forKey: engine.engineID)
        }
        systemRuntimeEngines.removeAll { $0.source == source }
        attachedRuntimeEngines.removeAll { $0.source == source }
        for engine in bonjourRuntimeEngines where engine.source == source {
            directBonjourEngines.remove(ObjectIdentifier(engine))
        }
        bonjourRuntimeEngines.removeAll { $0.source == source }
        rebuildSections()

        if let pendingBonjourReconnect {
            #log(.info,"Reconnecting to pending Bonjour endpoint after termination: \(pendingBonjourReconnect.name, privacy: .public)")
            Task { @MainActor in
                await self.connectToBonjourEndpoint(pendingBonjourReconnect)
            }
        }
    }

    public func terminateAttachedRuntimeEngine(name: String, identifier: String, isSandbox: Bool) {
        if isSandbox {
            terminateRuntimeEngine(for: .localSocket(name: name, identifier: .init(rawValue: identifier), role: .client))
        } else {
            terminateRuntimeEngine(for: .remote(name: name, identifier: .init(rawValue: identifier), role: .client))
        }
    }

    // MARK: - Injected Endpoint Reconnection

    /// Reconnects to already-injected non-sandboxed apps by fetching their
    /// registered XPC endpoints from the Mach Service daemon.
    private func reconnectInjectedXPCEngines() async {
        do {
            let injectedEndpoints = try await runtimeInjectClient.fetchAllInjectedEndpoints()
            guard !injectedEndpoints.isEmpty else {
                #log(.info, "No injected endpoints to reconnect")
                return
            }
            #log(.info, "Found \(injectedEndpoints.count) injected endpoint(s) to reconnect")

            for injectedEndpointInfo in injectedEndpoints {
                do {
                    let runtimeEngine = RuntimeEngine(
                        source: .remote(
                            name: injectedEndpointInfo.appName,
                            identifier: .init(rawValue: "\(injectedEndpointInfo.pid)"),
                            role: .client
                        )
                    )
                    try await runtimeEngine.connect(xpcServerEndpoint: injectedEndpointInfo.endpoint)
                    #log(.info, "Reconnected to injected app: \(injectedEndpointInfo.appName, privacy: .public) (PID: \(injectedEndpointInfo.pid))")
                    attachedRuntimeEngines.append(runtimeEngine)
                    observeRuntimeEngineState(runtimeEngine)
                    cacheLocalAppIcon(for: runtimeEngine, processIdentifier: "\(injectedEndpointInfo.pid)")
                } catch {
                    #log(.error, "Failed to reconnect to injected app \(injectedEndpointInfo.appName, privacy: .public) (PID: \(injectedEndpointInfo.pid)): \(error, privacy: .public)")
                    // Clean up stale endpoint
                    try? await runtimeInjectClient.removeInjectedEndpoint(pid: injectedEndpointInfo.pid)
                }
            }
            rebuildSections()
        } catch {
            #log(.error, "Failed to fetch injected endpoints: \(error, privacy: .public)")
        }
    }

    /// Reconnects to already-injected sandboxed apps by reading persisted
    /// socket endpoint records and recreating socket servers.
    private func reconnectInjectedSocketEngines() async {
        let records = loadInjectedSocketEndpointRecords()
        guard !records.isEmpty else {
            Self.logger.info("No injected socket endpoints to reconnect")
            return
        }
        Self.logger.info("Found \(records.count) injected socket endpoint(s) to reconnect")

        var aliveRecords: [InjectedSocketEndpointRecord] = []

        for record in records {
            // Check if the process is still alive
            guard kill(record.pid, 0) == 0 || errno == EPERM else {
                Self.logger.info("Injected socket endpoint PID \(record.pid) is no longer alive, removing record")
                continue
            }

            do {
                let runtimeEngine = RuntimeEngine(
                    source: .localSocket(
                        name: record.appName,
                        identifier: .init(rawValue: "\(record.pid)"),
                        role: .client
                    )
                )
                try await runtimeEngine.connect()
                Self.logger.info("Reconnected to injected sandboxed app: \(record.appName, privacy: .public) (PID: \(record.pid))")
                attachedRuntimeEngines.append(runtimeEngine)
                observeRuntimeEngineState(runtimeEngine)
                cacheLocalAppIcon(for: runtimeEngine, processIdentifier: "\(record.pid)")
                aliveRecords.append(record)
            } catch {
                Self.logger.error("Failed to reconnect to injected sandboxed app \(record.appName, privacy: .public) (PID: \(record.pid)): \(error, privacy: .public)")
            }
        }

        // Update the persisted records to only contain alive entries
        saveInjectedSocketEndpointRecords(aliveRecords)
        rebuildSections()
    }

    // MARK: - State Observation

    private func observeRuntimeEngineState(_ runtimeEngine: RuntimeEngine) {
        runtimeEngine.statePublisher.asObservable()
            .subscribeOnNextMainActor { [weak self, weak runtimeEngine] state in
                guard let self, let runtimeEngine else { return }
                switch state {
                case .initializing:
                    #log(.info,"Initializing runtime engine: \(runtimeEngine.source.description, privacy: .public)")
                case .connecting:
                    #log(.info,"Connecting to runtime engine: \(runtimeEngine.source.description, privacy: .public)")
                case .connected:
                    #log(.info,"Connected to runtime engine: \(runtimeEngine.source.description, privacy: .public)")
                    runtimeConnectionNotificationService.notifyConnected(source: runtimeEngine.source)
                case .disconnected(error: let error):
                    if let error {
                        #log(.error,"Disconnected from runtime engine: \(runtimeEngine.source.description, privacy: .public) with error: \(error, privacy: .public)")
                    } else {
                        #log(.info,"Disconnected from runtime engine: \(runtimeEngine.source.description, privacy: .public)")
                    }
                    runtimeConnectionNotificationService.notifyDisconnected(source: runtimeEngine.source, error: error)

                    self.cleanupMirroredEnginesOnDisconnect(of: runtimeEngine)

                    terminateRuntimeEngine(for: runtimeEngine.source)
                default:
                    break
                }
            }
            .disposed(by: rx.disposeBag)
    }

    /// Cleans up mirrored engines affected by a given engine's disconnect.
    ///
    /// Two distinct cases:
    ///
    /// 1. The disconnected engine IS itself a mirrored engine (its directTCP connection to a
    ///    proxy died). Remove only that specific entry; no peer-wide cleanup.
    ///
    /// 2. The disconnected engine is a direct peer (Bonjour client or system engine). The
    ///    peer can play either role in the topology, and we have to cover both:
    ///
    ///    - **Intermediate-node disconnect** — the peer was forwarding other hosts' engines
    ///      to us. Drop every mirror with `ownership == peer.hostID`, including transitive
    ///      entries (A → B → C, B disconnects → drop B's forwarded mirror of C). Handled by
    ///      `clearAllOwnedBy(hostID:)`.
    ///    - **Leaf-node disconnect** — the peer's own engines may have reached us via some
    ///      other forwarder, so they have `ownership = forwarder ≠ peer.hostID`. Drop every
    ///      mirror whose `engineID` prefix is `peer.hostID/` (A → B → C, C disconnects → drop
    ///      every mirror of C regardless of who forwarded it). Handled by
    ///      `clearAllWithHostID(hostID:)`.
    ///
    ///    Both run on every direct-peer disconnect — the disjoint match-keys mean the union
    ///    covers all topologies; the registry handles overlap gracefully (an entry removed
    ///    by the first call simply isn't seen by the second).
    private func cleanupMirroredEnginesOnDisconnect(of runtimeEngine: RuntimeEngine) {
        // Case 1: the disconnected engine is itself a mirrored entry.
        let ownMirrorRemovals = mirrorRegistry.clearOwnMirror(matching: runtimeEngine)
        if !ownMirrorRemovals.isEmpty {
            for removal in ownMirrorRemovals {
                let stopped = removal.engine
                Task { @MainActor in await stopped.stop() }
                engineIconCache.removeValue(forKey: removal.engineID)
            }
            mirroredEngines = mirrorRegistry.engines
            return
        }

        // Case 2: direct peer disconnect — handle both intermediate and leaf topologies.
        let disconnectedHostID = runtimeEngine.hostInfo.hostID
        let peerRemovals = mirrorRegistry.clearAllOwnedBy(hostID: disconnectedHostID)
        let originRemovals = mirrorRegistry.clearAllWithHostID(hostID: disconnectedHostID)
        let allRemovals = peerRemovals + originRemovals
        for removal in allRemovals {
            let stopped = removal.engine
            Task { @MainActor in await stopped.stop() }
            engineIconCache.removeValue(forKey: removal.engineID)
        }
        if !allRemovals.isEmpty {
            mirroredEngines = mirrorRegistry.engines
        }
    }

    // MARK: - Icon Management

    private func cacheLocalAppIcon(for engine: RuntimeEngine, processIdentifier pidString: String) {
        guard let pid = Int32(pidString) else { return }
        let app = NSRunningApplication(processIdentifier: pid)
        if let icon = app?.icon {
            engineIconCache[engine.engineID] = icon
        } else if let bundleURL = app?.bundleURL {
            engineIconCache[engine.engineID] = NSWorkspace.shared.icon(forFile: bundleURL.path)
        }
    }

    /// Returns the cached icon for a given engine, or nil if not yet available.
    public func cachedIcon(for engine: RuntimeEngine) -> NSImage? {
        engineIconCache[engine.engineID]
    }

    // MARK: - Engine Sharing (Server-Side)

    func buildEngineDescriptors() async -> [RemoteEngineDescriptor] {
        #log(.debug,"[EngineMirroring] buildEngineDescriptors called, runtimeEngines count: \(self.runtimeEngines.count, privacy: .public), proxyServers count: \(self.proxyServers.count, privacy: .public)")
        #log(.debug,"[EngineMirroring] proxyServer keys: \(Array(self.proxyServers.keys).joined(separator: ", "), privacy: .public)")
        var descriptors: [RemoteEngineDescriptor] = []
        for engine in runtimeEngines {
            let isBonjourServer = engine === bonjourServerEngine
            let localID = engine.source.identifier
            let hasProxy = proxyServers[localID] != nil
            #log(.debug,"[EngineMirroring] engine: \(localID, privacy: .public), isBonjourServer: \(isBonjourServer, privacy: .public), hasProxy: \(hasProxy, privacy: .public)")
            guard !isBonjourServer else { continue }
            guard let proxy = proxyServers[localID] else { continue }
            let globalID = "\(engine.hostInfo.hostID)/\(localID)"
            // Append our own instanceID to the origin chain so downstream peers
            // can detect cycles when the descriptor bounces back through us.
            let chainWithSelf = engine.originChain + [RuntimeNetworkBonjour.localInstanceID]
            let proxyHost = await proxy.host
            let proxyPort = await proxy.port
            let descriptor = RemoteEngineDescriptor(
                engineID: globalID,
                source: engine.source,
                hostName: engine.hostInfo.hostName,
                originChain: chainWithSelf,
                directTCPHost: proxyHost,
                directTCPPort: proxyPort,
                metadata: engine.hostInfo.metadata,
                iconData: await proxy.iconData()
            )
            #log(.debug,"[EngineMirroring] built descriptor: \(globalID, privacy: .public) at \(proxyHost, privacy: .public):\(proxyPort, privacy: .public)")
            descriptors.append(descriptor)
        }
        #log(.debug,"[EngineMirroring] buildEngineDescriptors returning \(descriptors.count, privacy: .public) descriptors")
        return descriptors
    }

    func startSharingEngines() {
        RuntimeEngine.engineListProvider = { [weak self] in
            guard let self else { return [] }
            return await self.buildEngineDescriptors()
        }

        RuntimeEngine.engineListChangedHandler = { [weak self] descriptors, engine in
            guard let self else { return }
            await MainActor.run {
                self.handleEngineListChanged(descriptors, from: engine)
            }
        }

        rx.runtimeEngines
            .driveOnNext { [weak self] engines in
                guard let self else { return }
                let ids = engines.map { $0.source.identifier }
                #log(.debug,"[EngineIcon] rx.runtimeEngines emitted \(engines.count, privacy: .public) engines: \(ids.joined(separator: ", "), privacy: .public)")
                self.updateProxyServers(for: engines)
            }
            .disposed(by: rx.disposeBag)

        // When a Bonjour client connects to our server, push the current engine list
        if let bonjourServerEngine {
            bonjourServerEngine.statePublisher.asObservable()
                .subscribeOnNextMainActor { [weak self] state in
                    guard let self else { return }
                    if case .connected = state {
                        #log(.info,"Bonjour server client connected, pushing engine list")
                        Task { @MainActor in
                            let descriptors = await self.buildEngineDescriptors()
                            try? await bonjourServerEngine.pushEngineListChanged(descriptors)
                        }
                    }
                }
                .disposed(by: rx.disposeBag)
        }
    }

    private func updateProxyServers(for engines: [RuntimeEngine]) {
        #log(.debug,"[EngineMirroring] updateProxyServers called with \(engines.count, privacy: .public) engines")
        let currentIDs = Set(engines.map { $0.source.identifier })
        let existingIDs = Set(proxyServers.keys)

        // Remove proxy servers for engines that no longer exist
        for id in existingIDs.subtracting(currentIDs) {
            #log(.debug,"[EngineMirroring] removing proxy server: \(id, privacy: .public)")
            let proxy = proxyServers.removeValue(forKey: id)
            Task.detached { await proxy?.stop() }
        }

        // Add proxy servers for new engines (non-blocking)
        for engine in engines {
            let id = engine.source.identifier
            guard !existingIDs.contains(id) else { continue }
            guard engine !== bonjourServerEngine else {
                #log(.debug,"[EngineMirroring] skipping bonjourServerEngine: \(id, privacy: .public)")
                continue
            }

            #log(.debug,"[EngineMirroring] starting proxy server for: \(id, privacy: .public)")
            let proxy = RuntimeEngineProxyServer(engine: engine, identifier: id)
            proxyServers[id] = proxy

            // Start proxy off main actor to avoid blocking
            Task.detached { [weak self] in
                do {
                    try await proxy.start()
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        proxyServers.removeValue(forKey: id)
                    }
                    return
                }

                // Push updated engine list after proxy is ready
                guard let self else { return }
                #log(.debug,"[EngineIcon] proxy \(id, privacy: .public) started, building descriptors to push...")
                let descriptors = await self.buildEngineDescriptors()
                #log(.debug,"[EngineIcon] pushing \(descriptors.count, privacy: .public) descriptors after proxy \(id, privacy: .public) ready")
                if let bonjourServerEngine = await MainActor.run(body: { self.bonjourServerEngine }) {
                    let serverState = bonjourServerEngine.state
                    #log(.debug,"[EngineIcon] bonjourServerEngine state: \(String(describing: serverState), privacy: .public)")
                    try? await bonjourServerEngine.pushEngineListChanged(descriptors)
                    #log(.debug,"[EngineIcon] pushEngineListChanged completed")
                } else {
                    #log(.debug,"[EngineIcon] bonjourServerEngine is nil, cannot push")
                }
            }
        }
    }

    // MARK: - Engine Mirroring (Client-Side)

    /// Owns the per-source dedup cache, ownership map, and the actual mirrored
    /// engine dictionary. All mutation goes through here so the reconcile rules
    /// can be exercised by unit tests without spinning up the full network stack.
    private let mirrorRegistry = RuntimeEngineMirrorRegistry()

    func handleEngineListChanged(_ descriptors: [RemoteEngineDescriptor], from engine: RuntimeEngine) {
        let sourceHostID = engine.hostInfo.hostID
        #log(.debug,"[EngineMirroring] handleEngineListChanged called with \(descriptors.count, privacy: .public) descriptors from source=\(sourceHostID, privacy: .public) (\(engine.source.description, privacy: .public))")

        for d in descriptors {
            #log(.debug,"[EngineMirroring]   descriptor: \(d.engineID, privacy: .public) host:\(d.directTCPHost, privacy: .public) port:\(d.directTCPPort, privacy: .public) originChain:\(d.originChain.joined(separator: ","), privacy: .public)")
        }

        let outcome = mirrorRegistry.reconcile(
            descriptors: descriptors,
            fromHostID: sourceHostID,
            localInstanceID: RuntimeNetworkBonjour.localInstanceID,
            engineFactory: { descriptor in
                RuntimeEngine(
                    source: .directTCP(
                        name: descriptor.source.description,
                        host: descriptor.directTCPHost,
                        port: descriptor.directTCPPort,
                        role: .client
                    ),
                    hostInfo: HostInfo(
                        hostID: descriptor.originChain.first ?? "",
                        hostName: descriptor.hostName,
                        metadata: descriptor.metadata
                    ),
                    originChain: descriptor.originChain
                )
            }
        )

        switch outcome {
        case .skippedDuplicate:
            #log(.debug,"[EngineMirroring] skipping duplicate descriptor set from \(sourceHostID, privacy: .public)")
            return

        case .applied(let removed, let added):
            for removal in removed {
                let stopped = removal.engine
                Task { @MainActor in await stopped.stop() }
                engineIconCache.removeValue(forKey: removal.engineID)
            }

            for addition in added {
                let mirroredEngine = addition.engine
                let descriptor = addition.descriptor
                observeRuntimeEngineState(mirroredEngine)

                if let iconData = descriptor.iconData, let image = NSImage(data: iconData) {
                    engineIconCache[mirroredEngine.engineID] = image
                }

                Task { @MainActor in
                    do {
                        try await mirroredEngine.connect()
                    } catch {
                        #log(.error,"Failed to connect mirrored engine \(descriptor.engineID, privacy: .public): \(error, privacy: .public)")
                    }
                }
            }

            mirroredEngines = mirrorRegistry.engines
            rebuildSections()
        }
    }

    // MARK: - Section Building

    private func rebuildSections() {
        var sections: [RuntimeEngineSection] = []
        var hostIDToIndex: [String: Int] = [:]

        for engine in runtimeEngines {
            // Hide Bonjour client engines that serve as management connections only.
            // Direct Bonjour engines (remotes without engine sharing) are shown in the UI.
            if bonjourRuntimeEngines.contains(where: { $0 === engine }),
               !directBonjourEngines.contains(ObjectIdentifier(engine)) { continue }
            let hostID = engine.hostInfo.hostID
            if let index = hostIDToIndex[hostID] {
                let section = sections[index]
                sections[index] = RuntimeEngineSection(
                    hostName: section.hostName,
                    hostID: section.hostID,
                    engines: section.engines + [engine]
                )
            } else {
                hostIDToIndex[hostID] = sections.count
                sections.append(RuntimeEngineSection(
                    hostName: engine.hostInfo.hostName,
                    hostID: hostID,
                    engines: [engine]
                ))
            }
        }

        sections = deduplicateForwardedMirrors(in: sections)

        let sectionSummary = sections.map { "\($0.hostName)(\($0.engines.count))" }.joined(separator: ", ")
        #log(.debug,"[EngineIcon] rebuildSections: \(sections.count, privacy: .public) sections — \(sectionSummary, privacy: .public)")
        runtimeEngineSections = sections
    }

    /// Drops mirrored engines that duplicate an entry the local app already reaches
    /// directly. The duplicates come in via the engine sharing protocol — e.g. a
    /// neighbouring Mac directly connects to an iPhone (or to another Mac that
    /// hadn't yet returned an engine list), wraps that connection as an engine, and
    /// forwards the descriptor to us. We then mirror it, producing a second entry
    /// under the same section with the same display name as the route we already
    /// hold ourselves.
    ///
    /// Doing this in the section-build step (instead of inside the mirror reconcile
    /// or as an evict on direct-connect) means `mirrorRegistry` keeps the alternate
    /// route around. If the local direct path drops, the mirror is still present in
    /// `mirroredEngines` and reappears on the very next `rebuildSections` call —
    /// no waiting for the upstream peer to re-push.
    ///
    /// `localRouteNames` is built from *all* of this host's local-route engines —
    /// including Bonjour client engines that `rebuildSections` hides as management
    /// connections — because forwarded mirrors of those exact connections are still
    /// what we need to suppress.
    private func deduplicateForwardedMirrors(in sections: [RuntimeEngineSection]) -> [RuntimeEngineSection] {
        return sections.map { section in
            let localRouteNames = Set(
                runtimeEngines
                    .filter { engine in
                        guard engine.hostInfo.hostID == section.hostID else { return false }
                        return systemRuntimeEngines.contains(where: { $0 === engine })
                            || attachedRuntimeEngines.contains(where: { $0 === engine })
                            || bonjourRuntimeEngines.contains(where: { $0 === engine })
                    }
                    .map { $0.source.description }
            )
            guard !localRouteNames.isEmpty else { return section }

            let dedupedEngines = section.engines.filter { engine in
                // Always keep direct local routes that survived rebuildSections.
                if systemRuntimeEngines.contains(where: { $0 === engine })
                    || attachedRuntimeEngines.contains(where: { $0 === engine })
                    || bonjourRuntimeEngines.contains(where: { $0 === engine }) {
                    return true
                }
                // A mirror with the same display name as a local route to this same
                // host is the same remote engine reached the long way round; drop it.
                return !localRouteNames.contains(engine.source.description)
            }

            guard dedupedEngines.count != section.engines.count else { return section }
            return RuntimeEngineSection(
                hostName: section.hostName,
                hostID: section.hostID,
                engines: dedupedEngines
            )
        }
    }
}

extension RuntimeEngineManager: ReactiveCompatible {}

@MainActor
extension Reactive where Base == RuntimeEngineManager {
    public var runtimeEngines: Driver<[RuntimeEngine]> {
        Driver.combineLatest(
            base.$systemRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []),
            base.$attachedRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []),
            base.$bonjourRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []),
            base.$mirroredEngines.asObservable().asDriver(onErrorJustReturn: [:]),
            resultSelector: { $0 + $1 + $2 + $3.values.elements }
        )
    }

    public var runtimeEngineSections: Driver<[RuntimeEngineSection]> {
        base.$runtimeEngineSections.asObservable().asDriver(onErrorJustReturn: [])
    }
}

// MARK: - Dependencies

@MainActor
private enum RuntimeEngineManagerKey: @MainActor DependencyKey {
    static let liveValue = RuntimeEngineManager.shared
}

@MainActor
extension DependencyValues {
    public var runtimeEngineManager: RuntimeEngineManager {
        get { self[RuntimeEngineManagerKey.self] }
        set { self[RuntimeEngineManagerKey.self] = newValue }
    }
}
#endif
