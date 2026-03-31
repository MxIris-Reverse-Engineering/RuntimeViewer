import AppKit
import Foundation
import FoundationToolbox
import OrderedCollections
import ServiceManagement
import SystemConfiguration
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerArchitectures
import RuntimeViewerHelperClient
import RuntimeViewerCatalystExtensions

@Loggable
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
                Task {
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
            }
        )

        Task {
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

        Task {
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
            #log(.info,"Skipping duplicate Bonjour endpoint: \(endpoint.name, privacy: .public)")
            return
        }
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
            Task {
                do {
                    #log(.info,"[MIRROR-DEBUG] requesting engine list from \(endpoint.name, privacy: .public)...")
                    let descriptors = try await runtimeEngine.requestEngineList()
                    #log(.info,"[MIRROR-DEBUG] received \(descriptors.count, privacy: .public) descriptors from \(endpoint.name, privacy: .public)")
                    if descriptors.isEmpty {
                        // Remote doesn't support engine sharing (e.g. iOS, injected app).
                        // Show the Bonjour engine directly in the Toolbar.
                        #log(.info,"[MIRROR-DEBUG] remote \(endpoint.name, privacy: .public) returned 0 descriptors, marking as direct engine")
                        self.directBonjourEngines.insert(ObjectIdentifier(runtimeEngine))
                        self.rebuildSections()
                    } else {
                        self.handleEngineListChanged(descriptors, from: runtimeEngine)
                    }
                } catch {
                    #log(.error,"[MIRROR-DEBUG] Failed to request engine list: \(error, privacy: .public)")
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
        if case .bonjour(let name, _, let role) = source, role.isClient {
            knownBonjourEndpointNames.remove(name)
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
    @concurrent
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
            .subscribeOnNext { [weak self, weak runtimeEngine] state in
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

                    // Clean up mirrored engines from the disconnected host
                    let hostID = runtimeEngine.hostInfo.hostID
                    for (id, engine) in self.mirroredEngines where engine.hostInfo.hostID == hostID {
                        Task { await engine.stop() }
                        self.mirroredEngines.removeValue(forKey: id)
                        self.engineIconCache.removeValue(forKey: id)
                    }

                    terminateRuntimeEngine(for: runtimeEngine.source)
                default:
                    break
                }
            }
            .disposed(by: rx.disposeBag)
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
        #log(.info,"[MIRROR-DEBUG] buildEngineDescriptors called, runtimeEngines count: \(self.runtimeEngines.count, privacy: .public), proxyServers count: \(self.proxyServers.count, privacy: .public)")
        #log(.info,"[MIRROR-DEBUG] proxyServer keys: \(Array(self.proxyServers.keys).joined(separator: ", "), privacy: .public)")
        var descriptors: [RemoteEngineDescriptor] = []
        for engine in runtimeEngines {
            let isBonjourServer = engine === bonjourServerEngine
            let localID = engine.source.identifier
            let hasProxy = proxyServers[localID] != nil
            #log(.info,"[MIRROR-DEBUG] engine: \(localID, privacy: .public), isBonjourServer: \(isBonjourServer, privacy: .public), hasProxy: \(hasProxy, privacy: .public)")
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
            #log(.info,"[MIRROR-DEBUG] built descriptor: \(globalID, privacy: .public) at \(proxyHost, privacy: .public):\(proxyPort, privacy: .public)")
            descriptors.append(descriptor)
        }
        #log(.info,"[MIRROR-DEBUG] buildEngineDescriptors returning \(descriptors.count, privacy: .public) descriptors")
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
                #log(.info,"[ICON-DEBUG] rx.runtimeEngines emitted \(engines.count, privacy: .public) engines: \(ids.joined(separator: ", "), privacy: .public)")
                self.updateProxyServers(for: engines)
            }
            .disposed(by: rx.disposeBag)

        // When a Bonjour client connects to our server, push the current engine list
        if let bonjourServerEngine {
            bonjourServerEngine.statePublisher.asObservable()
                .subscribeOnNext { [weak self] state in
                    guard let self else { return }
                    if case .connected = state {
                        #log(.info,"Bonjour server client connected, pushing engine list")
                        Task {
                            let descriptors = await self.buildEngineDescriptors()
                            try? await bonjourServerEngine.pushEngineListChanged(descriptors)
                        }
                    }
                }
                .disposed(by: rx.disposeBag)
        }
    }

    private func updateProxyServers(for engines: [RuntimeEngine]) {
        #log(.info,"[MIRROR-DEBUG] updateProxyServers called with \(engines.count, privacy: .public) engines")
        let currentIDs = Set(engines.map { $0.source.identifier })
        let existingIDs = Set(proxyServers.keys)

        // Remove proxy servers for engines that no longer exist
        for id in existingIDs.subtracting(currentIDs) {
            #log(.info,"[MIRROR-DEBUG] removing proxy server: \(id, privacy: .public)")
            let proxy = proxyServers.removeValue(forKey: id)
            Task.detached { await proxy?.stop() }
        }

        // Add proxy servers for new engines (non-blocking)
        for engine in engines {
            let id = engine.source.identifier
            guard !existingIDs.contains(id) else { continue }
            guard engine !== bonjourServerEngine else {
                #log(.info,"[MIRROR-DEBUG] skipping bonjourServerEngine: \(id, privacy: .public)")
                continue
            }

            #log(.info,"[MIRROR-DEBUG] starting proxy server for: \(id, privacy: .public)")
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
                #log(.info,"[ICON-DEBUG] proxy \(id, privacy: .public) started, building descriptors to push...")
                let descriptors = await self.buildEngineDescriptors()
                #log(.info,"[ICON-DEBUG] pushing \(descriptors.count, privacy: .public) descriptors after proxy \(id, privacy: .public) ready")
                if let bonjourServerEngine = await MainActor.run(body: { self.bonjourServerEngine }) {
                    let serverState = bonjourServerEngine.state
                    #log(.info,"[ICON-DEBUG] bonjourServerEngine state: \(String(describing: serverState), privacy: .public)")
                    try? await bonjourServerEngine.pushEngineListChanged(descriptors)
                    #log(.info,"[ICON-DEBUG] pushEngineListChanged completed")
                } else {
                    #log(.info,"[ICON-DEBUG] bonjourServerEngine is nil, cannot push")
                }
            }
        }
    }

    // MARK: - Engine Mirroring (Client-Side)

    private var lastReceivedDescriptorIDs: Set<String> = []

    func handleEngineListChanged(_ descriptors: [RemoteEngineDescriptor], from engine: RuntimeEngine) {
        #log(.info,"[MIRROR-DEBUG] handleEngineListChanged called with \(descriptors.count, privacy: .public) descriptors from \(engine.source.description, privacy: .public)")

        // Filter out cycles first
        let filteredDescriptors = descriptors.filter { descriptor in
            if descriptor.originChain.contains(RuntimeNetworkBonjour.localInstanceID) {
                #log(.info,"[MIRROR-DEBUG] skipping \(descriptor.engineID, privacy: .public): cycle detected (originChain contains \(RuntimeNetworkBonjour.localInstanceID, privacy: .public))")
                return false
            }
            return true
        }

        // Dedup: skip if we already processed the exact same set of descriptors
        let newIDSet = Set(filteredDescriptors.map(\.engineID))
        #log(.info,"[ICON-DEBUG] handleEngineListChanged dedup check: lastIDs=\(self.lastReceivedDescriptorIDs.sorted().joined(separator: ", "), privacy: .public)")
        #log(.info,"[ICON-DEBUG] handleEngineListChanged dedup check: newIDs=\(newIDSet.sorted().joined(separator: ", "), privacy: .public)")
        if newIDSet == lastReceivedDescriptorIDs {
            #log(.info,"[ICON-DEBUG] skipping duplicate descriptor set!")
            return
        }
        lastReceivedDescriptorIDs = newIDSet
        #log(.info,"[ICON-DEBUG] descriptor set is NEW, proceeding with \(filteredDescriptors.count, privacy: .public) descriptors")

        for d in filteredDescriptors {
            #log(.info,"[MIRROR-DEBUG]   descriptor: \(d.engineID, privacy: .public) host:\(d.directTCPHost, privacy: .public) port:\(d.directTCPPort, privacy: .public) originChain:\(d.originChain.joined(separator: ","), privacy: .public)")
        }
        let currentIDs = Set(mirroredEngines.keys)
        let newIDs = newIDSet

        // Remove engines no longer in the list
        for id in currentIDs.subtracting(newIDs) {
            if let engine = mirroredEngines.removeValue(forKey: id) {
                Task { await engine.stop() }
                engineIconCache.removeValue(forKey: id)
            }
        }

        // Add new engines (cycles already filtered above)
        for descriptor in filteredDescriptors {
            guard !currentIDs.contains(descriptor.engineID) else { continue }

            let mirroredEngine = RuntimeEngine(
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

            mirroredEngines[descriptor.engineID] = mirroredEngine
            observeRuntimeEngineState(mirroredEngine)

            // Cache app icon from descriptor if available
            if let iconData = descriptor.iconData, let image = NSImage(data: iconData) {
                engineIconCache[mirroredEngine.engineID] = image
            }

            Task {
                do {
                    try await mirroredEngine.connect()
                } catch {
                    #log(.error,"Failed to connect mirrored engine \(descriptor.engineID, privacy: .public): \(error, privacy: .public)")
                }
            }
        }

        rebuildSections()
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

        let sectionSummary = sections.map { "\($0.hostName)(\($0.engines.count))" }.joined(separator: ", ")
        #log(.info,"[ICON-DEBUG] rebuildSections: \(sections.count, privacy: .public) sections — \(sectionSummary, privacy: .public)")
        runtimeEngineSections = sections
    }
}

extension RuntimeEngineManager: ReactiveCompatible {}

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

private enum RuntimeEngineManagerKey: DependencyKey {
    static let liveValue = RuntimeEngineManager.shared
}

extension DependencyValues {
    public var runtimeEngineManager: RuntimeEngineManager {
        get { self[RuntimeEngineManagerKey.self] }
        set { self[RuntimeEngineManagerKey.self] = newValue }
    }
}
