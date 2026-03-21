import Foundation
import FoundationToolbox
import ServiceManagement
import SystemConfiguration
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerArchitectures
import RuntimeViewerHelperClient
import RuntimeViewerCatalystExtensions

@MainActor
public final class RuntimeEngineManager: Loggable {
    public static let shared = RuntimeEngineManager()

    @Published
    public private(set) var systemRuntimeEngines: [RuntimeEngine] = []

    @Published
    public private(set) var attachedRuntimeEngines: [RuntimeEngine] = []

    @Published
    public private(set) var bonjourRuntimeEngines: [RuntimeEngine] = []

    private let browser = RuntimeNetworkBrowser()

    private var knownBonjourEndpointNames: Set<String> = []
    
    private static let maxRetryAttempts = 3
    
    private static let retryBaseDelay: UInt64 = 2_000_000_000 // 2 seconds in nanoseconds

    private var bonjourServerEngine: RuntimeEngine?

    private var proxyServers: [String: RuntimeEngineProxyServer] = [:]

    @Published
    public private(set) var mirroredEngines: [String: RuntimeEngine] = [:]

    @Published
    public private(set) var runtimeEngineSections: [RuntimeEngineSection] = []

    @Dependency(\.helperServiceManager)
    private var helperServiceManager

    @Dependency(\.runtimeConnectionNotificationService)
    private var runtimeConnectionNotificationService

    @Dependency(\.runtimeHelperClient)
    private var runtimeHelperClient

    private init() {
        Self.logger.info("RuntimeEngineManager initializing, local instance ID: \(RuntimeNetworkBonjour.localInstanceID, privacy: .public)")

        // Start Bonjour server BEFORE browser so the local service's TXT record
        // (containing localInstanceID) is registered with the Bonjour daemon
        // by the time the browser discovers it.
        startBonjourServer()

        browser.start(
            onAdded: { [weak self] endpoint in
                guard let self else { return }
                if endpoint.instanceID == RuntimeNetworkBonjour.localInstanceID {
                    Self.logger.info("Skipping self Bonjour endpoint: \(endpoint.name, privacy: .public), instanceID: \(endpoint.instanceID ?? "nil", privacy: .public)")
                    return
                }
                Self.logger.info("Bonjour endpoint discovered: \(endpoint.name, privacy: .public), instanceID: \(endpoint.instanceID ?? "nil", privacy: .public), attempting connection...")
                Task {
                    await self.connectToBonjourEndpoint(endpoint)
                }
            },
            onRemoved: { [weak self] endpoint in
                guard let self else { return }
                Self.logger.info("Bonjour endpoint removed: \(endpoint.name, privacy: .public)")
                Task {
                    self.knownBonjourEndpointNames.remove(endpoint.name)
                }
            }
        )

        Task {
            do {
                Self.logger.info("Launching system runtime engines...")
                try await self.launchSystemRuntimeEngines()
                Self.logger.info("System runtime engines launched successfully")
            } catch {
                Self.logger.error("Failed to launch system runtime engines with error: \(error, privacy: .public)")
            }
        }

        startSharingEngines()
    }

    private func startBonjourServer() {
        let name = SCDynamicStoreCopyComputerName(nil, nil) as? String ?? ProcessInfo.processInfo.hostName
        let source = RuntimeSource.bonjour(name: name, identifier: .init(rawValue: name), role: .server)
        let engine = RuntimeEngine(source: source)
        bonjourServerEngine = engine

        Self.logger.info("Starting Bonjour server with name: \(name, privacy: .public)")

        Task {
            do {
                try await engine.connect()
                Self.logger.info("Bonjour server connected with name: \(name, privacy: .public)")
            } catch {
                Self.logger.error("Failed to start Bonjour server: \(error, privacy: .public)")
            }
        }
    }

    private func connectToBonjourEndpoint(_ endpoint: RuntimeNetworkEndpoint, attempt: Int = 0) async {
        guard !knownBonjourEndpointNames.contains(endpoint.name) else {
            Self.logger.info("Skipping duplicate Bonjour endpoint: \(endpoint.name, privacy: .public)")
            return
        }
        knownBonjourEndpointNames.insert(endpoint.name)

        do {
            let runtimeEngine = RuntimeEngine(source: .bonjour(name: endpoint.name, identifier: .init(rawValue: endpoint.name), role: .client))
            try await runtimeEngine.connect(bonjourEndpoint: endpoint)
            appendBonjourRuntimeEngine(runtimeEngine)
            Self.logger.info("Successfully connected to Bonjour endpoint: \(endpoint.name, privacy: .public)")

            // Request the remote peer's engine list for mirroring
            Task {
                do {
                    let descriptors = try await runtimeEngine.requestEngineList()
                    self.handleEngineListChanged(descriptors, from: runtimeEngine)
                } catch {
                    Self.logger.error("Failed to request engine list: \(error, privacy: .public)")
                }
            }
        } catch {
            Self.logger.error("Failed to connect to Bonjour endpoint: \(endpoint.name, privacy: .public) (attempt \(attempt + 1, privacy: .public)): \(error, privacy: .public)")

            if attempt < Self.maxRetryAttempts {
                let delay = Self.retryBaseDelay * UInt64(1 << attempt) // 2s, 4s, 8s
                Self.logger.info("Retrying Bonjour connection to \(endpoint.name, privacy: .public) in \(delay / 1_000_000_000, privacy: .public)s...")
                try? await Task.sleep(nanoseconds: delay)
                knownBonjourEndpointNames.remove(endpoint.name)
                await connectToBonjourEndpoint(endpoint, attempt: attempt + 1)
            } else {
                knownBonjourEndpointNames.remove(endpoint.name)
                Self.logger.error("Exhausted retry attempts for Bonjour endpoint: \(endpoint.name, privacy: .public)")
            }
        }
    }

    private func appendBonjourRuntimeEngine(_ bonjourRuntimeEngine: RuntimeEngine) {
        bonjourRuntimeEngines.append(bonjourRuntimeEngine)
        observeRuntimeEngineState(bonjourRuntimeEngine)
        rebuildSections()
    }

    public var runtimeEngines: [RuntimeEngine] {
        systemRuntimeEngines + attachedRuntimeEngines + bonjourRuntimeEngines + Array(mirroredEngines.values)
    }

    @concurrent
    public func launchSystemRuntimeEngines() async throws {
        Self.logger.info("Appending local runtime engine")
        systemRuntimeEngines.append(.local)
        rebuildSections()
        #if os(macOS)
        Self.logger.info("Creating Mac Catalyst client runtime engine...")
        let macCatalystClientEngine = RuntimeEngine(source: .macCatalystClient)
        try await macCatalystClientEngine.connect()
        Self.logger.info("Mac Catalyst client engine connected, launching helper...")
        try await runtimeHelperClient.launchMacCatalystHelper()
        Self.logger.info("Mac Catalyst helper launched successfully")
        systemRuntimeEngines.append(macCatalystClientEngine)
        observeRuntimeEngineState(macCatalystClientEngine)
        rebuildSections()
        #endif
    }

    @concurrent
    public func launchAttachedRuntimeEngine(name: String, identifier: String, isSandbox: Bool) async throws {
        let runtimeSource = if isSandbox {
            RuntimeSource.localSocket(name: name, identifier: .init(rawValue: identifier), role: .client)
        } else {
            RuntimeSource.remote(name: name, identifier: .init(rawValue: identifier), role: .client)
        }

        Self.logger.info("Launching attached runtime engine: \(name, privacy: .public) (identifier: \(identifier, privacy: .public), sandbox: \(isSandbox, privacy: .public))")
        let runtimeEngine = RuntimeEngine(source: runtimeSource)
        try await runtimeEngine.connect()
        Self.logger.info("Attached runtime engine connected: \(name, privacy: .public)")
        attachedRuntimeEngines.append(runtimeEngine)
        observeRuntimeEngineState(runtimeEngine)
        rebuildSections()
    }

    private func observeRuntimeEngineState(_ runtimeEngine: RuntimeEngine) {
        runtimeEngine.statePublisher.asObservable()
            .subscribeOnNext { [weak self, weak runtimeEngine] state in
                guard let self, let runtimeEngine else { return }
                switch state {
                case .initializing:
                    logger.info("Initializing runtime engine: \(runtimeEngine.source.description, privacy: .public)")
                case .connecting:
                    logger.info("Connecting to runtime engine: \(runtimeEngine.source.description, privacy: .public)")
                case .connected:
                    logger.info("Connected to runtime engine: \(runtimeEngine.source.description, privacy: .public)")
                    runtimeConnectionNotificationService.notifyConnected(source: runtimeEngine.source)
                case .disconnected(error: let error):
                    if let error {
                        logger.error("Disconnected from runtime engine: \(runtimeEngine.source.description, privacy: .public) with error: \(error, privacy: .public)")
                    } else {
                        logger.info("Disconnected from runtime engine: \(runtimeEngine.source.description, privacy: .public)")
                    }
                    runtimeConnectionNotificationService.notifyDisconnected(source: runtimeEngine.source, error: error)

                    // Clean up mirrored engines from the disconnected host
                    let hostID = runtimeEngine.hostInfo.hostID
                    for (id, engine) in self.mirroredEngines where engine.hostInfo.hostID == hostID {
                        Task { await engine.stop() }
                        self.mirroredEngines.removeValue(forKey: id)
                    }

                    terminateRuntimeEngine(for: runtimeEngine.source)
                default:
                    break
                }
            }
            .disposed(by: rx.disposeBag)
    }

    public func terminateRuntimeEngine(for source: RuntimeSource) {
        Self.logger.info("Terminating runtime engine: \(source.description, privacy: .public)")
        if case .bonjour(let name, _, let role) = source, role.isClient {
            knownBonjourEndpointNames.remove(name)
        }
        systemRuntimeEngines.removeAll { $0.source == source }
        attachedRuntimeEngines.removeAll { $0.source == source }
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

    // MARK: - Engine Sharing (Server-Side)

    func buildEngineDescriptors() async -> [RemoteEngineDescriptor] {
        var descriptors: [RemoteEngineDescriptor] = []
        for engine in runtimeEngines {
            guard engine !== bonjourServerEngine else { continue }
            guard let proxy = proxyServers[engine.source.identifier] else { continue }
            let descriptor = RemoteEngineDescriptor(
                engineID: engine.source.identifier,
                source: engine.source,
                hostName: engine.hostInfo.hostName,
                originChain: engine.originChain + [RuntimeNetworkBonjour.localInstanceID],
                directTCPHost: await proxy.host,
                directTCPPort: await proxy.port
            )
            descriptors.append(descriptor)
        }
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
                Task {
                    await self.updateProxyServers(for: engines)
                }
            }
            .disposed(by: rx.disposeBag)
    }

    private func updateProxyServers(for engines: [RuntimeEngine]) async {
        let currentIDs = Set(engines.map { $0.source.identifier })
        let existingIDs = Set(proxyServers.keys)

        // Remove proxy servers for engines that no longer exist
        for id in existingIDs.subtracting(currentIDs) {
            await proxyServers[id]?.stop()
            proxyServers.removeValue(forKey: id)
        }

        // Add proxy servers for new engines
        for engine in engines {
            let id = engine.source.identifier
            guard !existingIDs.contains(id) else { continue }
            guard engine !== bonjourServerEngine else { continue }

            do {
                let proxy = RuntimeEngineProxyServer(engine: engine, identifier: id)
                try await proxy.start()
                proxyServers[id] = proxy
            } catch {
                Self.logger.error("Failed to start proxy server for \(id, privacy: .public): \(error, privacy: .public)")
            }
        }

        // Notify connected Bonjour clients about the updated engine list
        if let bonjourServerEngine {
            let descriptors = await buildEngineDescriptors()
            try? await bonjourServerEngine.pushEngineListChanged(descriptors)
        }
    }

    // MARK: - Engine Mirroring (Client-Side)

    func handleEngineListChanged(_ descriptors: [RemoteEngineDescriptor], from engine: RuntimeEngine) {
        let currentIDs = Set(mirroredEngines.keys)
        let newIDs = Set(descriptors.map(\.engineID))

        // Remove engines no longer in the list
        for id in currentIDs.subtracting(newIDs) {
            if let engine = mirroredEngines.removeValue(forKey: id) {
                Task { await engine.stop() }
            }
        }

        // Add new engines
        for descriptor in descriptors {
            guard !currentIDs.contains(descriptor.engineID) else { continue }

            // Cycle check: skip if this instance is already in the origin chain
            if descriptor.originChain.contains(RuntimeNetworkBonjour.localInstanceID) {
                Self.logger.info("Skipping mirrored engine \(descriptor.engineID, privacy: .public): cycle detected")
                continue
            }

            // Dedup check: skip if an engine with the same identifier already exists locally
            if runtimeEngines.contains(where: { $0.source.identifier == descriptor.engineID }) {
                Self.logger.info("Skipping mirrored engine \(descriptor.engineID, privacy: .public): already exists")
                continue
            }

            let mirroredEngine = RuntimeEngine(
                source: .directTCP(
                    name: descriptor.hostName + "/" + descriptor.source.description,
                    host: descriptor.directTCPHost,
                    port: descriptor.directTCPPort,
                    role: .client
                ),
                hostInfo: HostInfo(
                    hostID: descriptor.originChain.first ?? "",
                    hostName: descriptor.hostName
                ),
                originChain: descriptor.originChain
            )

            mirroredEngines[descriptor.engineID] = mirroredEngine
            observeRuntimeEngineState(mirroredEngine)

            Task {
                do {
                    try await mirroredEngine.connect()
                } catch {
                    Self.logger.error("Failed to connect mirrored engine \(descriptor.engineID, privacy: .public): \(error, privacy: .public)")
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
            resultSelector: { $0 + $1 + $2 + Array($3.values) }
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
