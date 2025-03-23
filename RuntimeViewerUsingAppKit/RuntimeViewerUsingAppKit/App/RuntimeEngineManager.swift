//
//  RuntimeEngineManager.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 11/28/24.
//

import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerArchitectures

public final class RuntimeEngineManager {
    public static let shared = RuntimeEngineManager()

    @Observed
    public private(set) var systemRuntimeEngines: [RuntimeEngine] = []

    @Observed
    public private(set) var attachedRuntimeEngines: [RuntimeEngine] = []
    
    @Observed
    public private(set) var bonjourRuntimeEngines: [RuntimeEngine] = []
    
    private let browser = RuntimeNetworkBrowser()
    
    private init() {
        browser.start { [weak self] endpoint in
            guard let self else { return }
            Task { @MainActor in
                self.bonjourRuntimeEngines.append(try await .init(source: .bonjourClient(endpoint: endpoint)))
            }
        }
    }
    
    public var runtimeEngines: [RuntimeEngine] {
        systemRuntimeEngines + attachedRuntimeEngines + bonjourRuntimeEngines
    }
    
    public nonisolated func launchSystemRuntimeEngines() async throws {
        systemRuntimeEngines.append(.shared)
        systemRuntimeEngines.append(try await .macCatalystClient())
    }
    
    public func launchAttachedRuntimeEngine(name: String, identifier: String) async throws {
        attachedRuntimeEngines.append(try await RuntimeEngine(source: .remote(name: name, identifier: .init(rawValue: identifier), role: .client)))
    }
}

extension RuntimeEngineManager: ReactiveCompatible {}

extension Reactive where Base == RuntimeEngineManager {
    public var runtimeEngines: Driver<[RuntimeEngine]> {
        Driver.combineLatest(base.$systemRuntimeEngines.asDriver(), base.$attachedRuntimeEngines.asDriver(), base.$bonjourRuntimeEngines.asDriver(), resultSelector: { $0 + $1 + $2 })
    }
}
