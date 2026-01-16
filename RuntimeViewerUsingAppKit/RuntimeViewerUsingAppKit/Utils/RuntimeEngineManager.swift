import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerArchitectures

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
                    Self.logger.error("\(error, privacy: .public)")
                }
            }
        }
        Task.detached {
            do {
                try await self.launchSystemRuntimeEngines()
            } catch {
                Self.logger.error("\(error, privacy: .public)")
            }
        }
    }

    private func appendBonjourRuntimeEngine(_ bonjourRuntimeEngine: RuntimeEngine) {
        bonjourRuntimeEngines.append(bonjourRuntimeEngine)
    }

    public var runtimeEngines: [RuntimeEngine] {
        systemRuntimeEngines + attachedRuntimeEngines + bonjourRuntimeEngines
    }

    public func launchSystemRuntimeEngines() async throws {
        systemRuntimeEngines.append(.shared)
        #if os(macOS)
        try systemRuntimeEngines.append(await .macCatalystClient())
        #endif
    }

    public func launchAttachedRuntimeEngine(name: String, identifier: String, isSandbox: Bool) async throws {
        if isSandbox {
            try attachedRuntimeEngines.append(await RuntimeEngine(source: .localSocketClient(name: name, identifier: .init(rawValue: identifier))))
        } else {
            try attachedRuntimeEngines.append(await RuntimeEngine(source: .remote(name: name, identifier: .init(rawValue: identifier), role: .client)))
        }
    }
}


extension RuntimeEngineManager: ReactiveCompatible {}

extension Reactive where Base == RuntimeEngineManager {
    public var runtimeEngines: Driver<[RuntimeEngine]> {
        Driver.combineLatest(base.$systemRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []), base.$attachedRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []), base.$bonjourRuntimeEngines.asObservable().asDriver(onErrorJustReturn: []), resultSelector: { $0 + $1 + $2 })
    }
}
