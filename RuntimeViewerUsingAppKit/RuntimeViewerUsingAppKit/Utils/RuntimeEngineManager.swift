import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerArchitectures
import Dependencies

public final class RuntimeEngineManager: Loggable {
    public static let shared = RuntimeEngineManager()

    @Published
    public private(set) var systemRuntimeEngines: [RuntimeEngine] = []

    @Published
    public private(set) var attachedRuntimeEngines: [RuntimeEngine] = []

    @Published
    public private(set) var bonjourRuntimeEngines: [RuntimeEngine] = []

    private let browser = RuntimeNetworkBrowser()

    private init() {
        browser.start { [weak self] endpoint in
            guard let self else { return }
            Task { @MainActor in
                do {
                    try await self.appendBonjourRuntimeEngine(.init(source: .bonjourClient(endpoint: endpoint)))
                } catch {
                    Self.logger.error("Failed to connect to bonjour runtime engine at endpoint: \("\(endpoint)", privacy: .public) with error: \(error, privacy: .public)")
                }
            }
        }
        Task {
            do {
                try await self.launchSystemRuntimeEngines()
            } catch {
                Self.logger.error("Failed to launch system runtime engines with error: \(error, privacy: .public)")
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
        systemRuntimeEngines.append(.shared)
        #if os(macOS)
        try await systemRuntimeEngines.append(.macCatalystClient())
        #endif
    }

    @concurrent
    public func launchAttachedRuntimeEngine(name: String, identifier: String, isSandbox: Bool) async throws {
        let runtimeSource = if isSandbox {
            RuntimeSource.localSocketClient(name: name, identifier: .init(rawValue: identifier))
        } else {
            RuntimeSource.remote(name: name, identifier: .init(rawValue: identifier), role: .client)
        }

        let runtimeEngine = try await RuntimeEngine(source: runtimeSource)
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
                    ConnectionNotificationService.shared.notifyConnected(source: runtimeEngine.source)
                case .disconnected(error: let error):
                    if let error {
                        logger.error("Disconnected from runtime engine: \(runtimeEngine.source.description, privacy: .public) with error: \(error, privacy: .public)")
                    } else {
                        logger.info("Disconnected from runtime engine: \(runtimeEngine.source.description, privacy: .public)")
                    }
                    ConnectionNotificationService.shared.notifyDisconnected(source: runtimeEngine.source, error: error)
                    terminateRuntimeEngine(for: runtimeEngine.source)
                default:
                    break
                }
            }
            .disposed(by: rx.disposeBag)
    }

    public func terminateRuntimeEngine(for source: RuntimeSource) {
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
