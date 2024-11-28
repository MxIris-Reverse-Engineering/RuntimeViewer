//
//  RuntimeEngineManager.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 11/28/24.
//

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class RuntimeEngineManager {
    public static let shared = RuntimeEngineManager()

    @Observed
    public private(set) var systemRuntimeEngines: [RuntimeEngine] = []

    @Observed
    public private(set) var attachedRuntimeEngines: [RuntimeEngine] = []
    
    public var runtimeEngines: [RuntimeEngine] {
        systemRuntimeEngines + attachedRuntimeEngines
    }
    
    public func launchSystemRuntimeEngines() async throws {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                systemRuntimeEngines.append(.shared)
                continuation.resume()
            }
        }
        systemRuntimeEngines.append(try await .macCatalystClient())
    }
    
    public func launchAttachedRuntimeEngine(name: String, identifier: String) async throws {
        attachedRuntimeEngines.append(try await RuntimeEngine(name: name, identifier: .init(rawValue: identifier), role: .client))
    }
}

extension RuntimeEngineManager: ReactiveCompatible {}

extension Reactive where Base == RuntimeEngineManager {
    public var runtimeEngines: Driver<[RuntimeEngine]> {
        Driver.combineLatest(base.$systemRuntimeEngines.asDriver(), base.$attachedRuntimeEngines.asDriver(), resultSelector: +)
    }
}
