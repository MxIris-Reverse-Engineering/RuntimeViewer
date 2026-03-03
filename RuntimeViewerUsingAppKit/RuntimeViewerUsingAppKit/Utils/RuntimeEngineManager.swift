import Foundation
import FoundationToolbox
import ServiceManagement
import SystemConfiguration
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerArchitectures
import RuntimeViewerHelperClient
import RuntimeViewerCatalystExtensions

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

    @Dependency(\.helperServiceManager)
    private var helperServiceManager

    @Dependency(\.runtimeConnectionNotificationService)
    private var runtimeConnectionNotificationService

    @Dependency(\.runtimeHelperClient)
    private var runtimeHelperClient

    private init() {
        Self.logger.info("RuntimeEngineManager initializing, local instance ID: \(RuntimeNetworkBonjour.localInstanceID, privacy: .public)")

        browser.start(
            onAdded: { [weak self] endpoint in
                guard let self else { return }
                if endpoint.instanceID == RuntimeNetworkBonjour.localInstanceID {
                    Self.logger.info("Skipping self Bonjour endpoint: \(endpoint.name, privacy: .public)")
                    return
                }
                Self.logger.info("Bonjour endpoint discovered: \(endpoint.name, privacy: .public), attempting connection...")
                Task { @MainActor in
                    await self.connectToBonjourEndpoint(endpoint)
                }
            },
            onRemoved: { [weak self] endpoint in
                guard let self else { return }
                Self.logger.info("Bonjour endpoint removed: \(endpoint.name, privacy: .public)")
                Task { @MainActor in
                    self.knownBonjourEndpointNames.remove(endpoint.name)
                }
            }
        )

        startBonjourServer()

        Task {
            do {
                Self.logger.info("Launching system runtime engines...")
                try await self.launchSystemRuntimeEngines()
                Self.logger.info("System runtime engines launched successfully")
            } catch {
                Self.logger.error("Failed to launch system runtime engines with error: \(error, privacy: .public)")
            }
        }
    }

    private func startBonjourServer() {
        let name = SCDynamicStoreCopyComputerName(nil, nil) as? String ?? ProcessInfo.processInfo.hostName
        let engine = RuntimeEngine(source: .bonjourServer(name: name, identifier: .init(rawValue: name)))
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

    @MainActor
    private func connectToBonjourEndpoint(_ endpoint: RuntimeNetworkEndpoint, attempt: Int = 0) async {
        guard !knownBonjourEndpointNames.contains(endpoint.name) else {
            Self.logger.info("Skipping duplicate Bonjour endpoint: \(endpoint.name, privacy: .public)")
            return
        }
        knownBonjourEndpointNames.insert(endpoint.name)

        do {
            let runtimeEngine = RuntimeEngine(source: .bonjourClient(endpoint: endpoint))
            try await runtimeEngine.connect()
            appendBonjourRuntimeEngine(runtimeEngine)
            Self.logger.info("Successfully connected to Bonjour endpoint: \(endpoint.name, privacy: .public)")
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
    }

    public var runtimeEngines: [RuntimeEngine] {
        systemRuntimeEngines + attachedRuntimeEngines + bonjourRuntimeEngines
    }

    @concurrent
    public func launchSystemRuntimeEngines() async throws {
        Self.logger.info("Appending local runtime engine")
        systemRuntimeEngines.append(.local)
        #if os(macOS)
        Self.logger.info("Creating Mac Catalyst client runtime engine...")
        let macCatalystClientEngine = RuntimeEngine(source: .macCatalystClient)
        try await macCatalystClientEngine.connect()
        Self.logger.info("Mac Catalyst client engine connected, launching helper...")
        try await runtimeHelperClient.launchMacCatalystHelper()
        Self.logger.info("Mac Catalyst helper launched successfully")
        systemRuntimeEngines.append(macCatalystClientEngine)
        observeRuntimeEngineState(macCatalystClientEngine)
        #endif
    }

    @concurrent
    public func launchAttachedRuntimeEngine(name: String, identifier: String, isSandbox: Bool) async throws {
        let runtimeSource = if isSandbox {
            RuntimeSource.localSocketClient(name: name, identifier: .init(rawValue: identifier))
        } else {
            RuntimeSource.remote(name: name, identifier: .init(rawValue: identifier), role: .client)
        }

        Self.logger.info("Launching attached runtime engine: \(name, privacy: .public) (identifier: \(identifier, privacy: .public), sandbox: \(isSandbox, privacy: .public))")
        let runtimeEngine = RuntimeEngine(source: runtimeSource)
        try await runtimeEngine.connect()
        Self.logger.info("Attached runtime engine connected: \(name, privacy: .public)")
        attachedRuntimeEngines.append(runtimeEngine)
        observeRuntimeEngineState(runtimeEngine)
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
                    terminateRuntimeEngine(for: runtimeEngine.source)
                default:
                    break
                }
            }
            .disposed(by: rx.disposeBag)
    }

    public func terminateRuntimeEngine(for source: RuntimeSource) {
        Self.logger.info("Terminating runtime engine: \(source.description, privacy: .public)")
        if case .bonjourClient(let endpoint) = source {
            knownBonjourEndpointNames.remove(endpoint.name)
        }
        systemRuntimeEngines.removeAll { $0.source == source }
        attachedRuntimeEngines.removeAll { $0.source == source }
        bonjourRuntimeEngines.removeAll { $0.source == source }
    }

    public func terminateAttachedRuntimeEngine(name: String, identifier: String, isSandbox: Bool) {
        if isSandbox {
            terminateRuntimeEngine(for: .localSocketClient(name: name, identifier: .init(rawValue: identifier)))
        } else {
            terminateRuntimeEngine(for: .remote(name: name, identifier: .init(rawValue: identifier), role: .client))
        }
    }
}

extension RuntimeEngineManager: ReactiveCompatible {}

extension Reactive where Base == RuntimeEngineManager {
    public var runtimeEngines: Driver<[RuntimeEngine]> {
        Driver.combineLatest(base.$systemRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []), base.$attachedRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []), base.$bonjourRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []), resultSelector: { $0 + $1 + $2 })
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
