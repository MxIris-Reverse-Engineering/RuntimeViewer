import Foundation
import RuntimeViewerCommunication

public final class RuntimeEngineManager {
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
                try await self.appendBonjourRuntimeEngine(.init(source: .bonjourClient(endpoint: endpoint)))
            }
        }
        Task.detached {
            do {
                try await self.launchSystemRuntimeEngines()
            } catch {
                NSLog("%@", error as NSError)
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

    public func launchAttachedRuntimeEngine(name: String, identifier: String) async throws {
        try attachedRuntimeEngines.append(await RuntimeEngine(source: .remote(name: name, identifier: .init(rawValue: identifier), role: .client)))
    }
}


