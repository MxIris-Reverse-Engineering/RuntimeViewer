#if os(macOS)

import Combine
import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement

extension LocalEngineManagerSuites {
    /// Bringing up the system engines where the platform's seams leave the Mac
    /// Catalyst launch out, and the relaunch the helper daemon's availability
    /// asks for where they do not. Every manager here lists `.local`, so each is
    /// made with `RuntimeSharedCacheEligibility.unavailable`: it hands `.local`
    /// no owners and leaves none behind for the suites after it.
    @Suite("RuntimeEngineManager system engines")
    @MainActor
    struct SystemEngineLaunchTests {
        private typealias MacCatalystLaunching = RuntimeEngineManager.MacCatalystLaunching

        /// A `.remote` server engine answers `requestEngineList` locally: the
        /// cheapest deterministic "the helper replied".
        private static func answeringEngine() -> RuntimeEngine {
            RuntimeEngine(
                source: .remote(name: "Answering stand-in", identifier: "system-engine-launch-tests.answering", role: .server),
                engineID: "system-engine-launch-tests.answering.\(UUID().uuidString)"
            )
        }

        /// Polls `condition` for up to five seconds.
        private static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
            for _ in 0 ..< 250 {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return condition()
        }

        /// A process with no Mac Catalyst to launch — every platform but the
        /// Mac — brings up `.local` alone, and reports nothing missing.
        @Test("Without a Mac Catalyst launch the system engines are .local alone")
        func systemEnginesWithoutMacCatalystAreLocalOnly() async {
            let manager = RuntimeEngineManager(
                configuration: .application,
                startupHandler: { _ in },
                macCatalystLaunching: nil,
                sharedCacheEligibility: .unavailable
            )
            var events: [RuntimeEngineManagerEvent] = []
            let subscription = manager.eventPublisher.sink { events.append($0) }
            defer { subscription.cancel() }

            await manager.launchSystemRuntimeEngines()
            await manager.waitForMacCatalystLaunch()
            await manager.waitForSharedCacheOwnersUpdate()

            #expect(manager.systemRuntimeEngines.count == 1)
            #expect(manager.systemRuntimeEngines.first === RuntimeEngine.local)
            #expect(manager.currentMacCatalystRuntimeEngine == nil)
            #expect(!events.contains { if case .catalystHelperUnavailable = $0 { return true } else { return false } })
        }

        /// The daemon being installed again empties the registry a running
        /// helper looks this process up in, so the helper's engine is
        /// relaunched. The manager hears it through the helper application's
        /// own publisher; it holds nothing of the daemon itself.
        ///
        /// Brought up for real, with a configuration that starts the system
        /// engines and nothing else — no Bonjour — so it is the initializer's
        /// subscription that is under test.
        @Test("The helper daemon becoming available relaunches the helper's engine")
        func daemonBecomingAvailableRelaunchesTheHelperEngine() async {
            let daemonAvailability = PassthroughSubject<Void, Never>()
            var helperLaunchCount = 0
            let configuration = RuntimeEngineManagerConfiguration(
                advertisesOverBonjour: false,
                browsesForPeers: false,
                sharesEnginesWithPeers: false,
                launchesSystemEngines: true,
                reconnectsInjectedEngines: false
            )
            let manager = RuntimeEngineManager(
                configuration: configuration,
                startupHandler: nil,
                macCatalystLaunching: MacCatalystLaunching(
                    makeConnectedEngine: { Self.answeringEngine() },
                    helperApplication: .init(
                        launch: { helperLaunchCount += 1 },
                        terminate: {},
                        handshakeTimeout: 2,
                        daemonBecameAvailable: { daemonAvailability.eraseToAnyPublisher() }
                    )
                ),
                sharedCacheEligibility: .unavailable
            )

            let launched = await Self.eventually { helperLaunchCount == 1 && manager.currentMacCatalystRuntimeEngine != nil }
            #expect(launched, "the system engines were not brought up")
            let firstEngine = manager.currentMacCatalystRuntimeEngine

            daemonAvailability.send(())
            let relaunched = await Self.eventually {
                helperLaunchCount == 2 && manager.currentMacCatalystRuntimeEngine.map { $0 !== firstEngine } == true
            }
            await manager.waitForMacCatalystLaunch()
            await manager.waitForSharedCacheOwnersUpdate()

            #expect(relaunched, "the helper's engine was not relaunched when the daemon became available")
            #expect(manager.systemRuntimeEngines.count == 2, ".local and one helper engine, the replaced one gone")
            #expect(manager.systemRuntimeEngines.first === RuntimeEngine.local)
            #expect(manager.systemRuntimeEngines.last === manager.currentMacCatalystRuntimeEngine)
        }
    }
}

#endif
