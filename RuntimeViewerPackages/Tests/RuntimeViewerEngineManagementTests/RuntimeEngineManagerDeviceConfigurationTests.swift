#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement

/// What the iOS, iPadOS and visionOS app's manager does, run on the Mac: the
/// `.deviceApplication` configuration with the values the platform seams have
/// off the Mac — no Mac Catalyst, files read in this process, no process to
/// probe for its shared cache. Nothing here starts Bonjour: the startup seam
/// records the steps, and the system engines are brought up by hand.
@Suite("RuntimeEngineManager device configuration")
@MainActor
struct RuntimeEngineManagerDeviceConfigurationTests {
    @Test(
        "The Bonjour server pushes this process's runtime data only when the configuration says so",
        arguments: [
            RuntimeEngineManagerConfiguration.application,
            .headlessHost,
            .deviceApplication,
        ]
    )
    func bonjourServerPushesRuntimeDataOnlyWhenConfigured(configuration: RuntimeEngineManagerConfiguration) {
        let engine = RuntimeEngineManager.makeBonjourServerEngine(named: "Device Configuration Tests", configuration: configuration)

        #expect(engine.pushesRuntimeData == configuration.bonjourServerPushesRuntimeData)
        #expect(engine.source == .bonjour(name: "Device Configuration Tests", identifier: "Device Configuration Tests", role: .server))
    }
}

extension LocalEngineManagerSuites {
    @Suite("RuntimeEngineManager device configuration on the Mac")
    @MainActor
    struct DeviceConfiguredManagerTests {
        @Test("A manager configured as on a device lists .local and the files it reads, and nothing else")
        func deviceConfiguredManagerOnMacListsOnlyLocal() async throws {
            var steps: [RuntimeEngineManagerConfiguration.StartupStep] = []
            let manager = RuntimeEngineManager(
                configuration: .deviceApplication,
                startupHandler: { steps.append($0) },
                macCatalystLaunching: nil,
                sharedCacheEligibility: .unavailable
            )
            manager.fileReading = .inThisProcess

            #expect(steps == [.bonjourServer, .systemEngines], "no browser, no reconnection, no sharing")

            await manager.launchSystemRuntimeEngines()
            await manager.waitForMacCatalystLaunch()
            let file = try RuntimeFile(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
            let fileEngine = try await manager.startReading(file)
            await manager.waitForSharedCacheOwnersUpdate()

            #expect(manager.systemRuntimeEngines.count == 1)
            #expect(manager.systemRuntimeEngines.first === RuntimeEngine.local)
            #expect(manager.currentMacCatalystRuntimeEngine == nil)
            #expect(manager.attachedRuntimeEngines.isEmpty)
            #expect(manager.bonjourRuntimeEngines.isEmpty)
            #expect(manager.mirroredEngines.isEmpty)
            #expect(manager.fileRuntimeEngines.map(\.engineID) == [fileEngine.engineID])
            #expect(!(await fileEngine.forwardsRequests))
            #expect(manager.runtimeEngineSections.map(\.hostID) == [RuntimeEngine.local.hostInfo.hostID, RuntimeHostInfo.files.hostID])
        }
    }
}

#endif
