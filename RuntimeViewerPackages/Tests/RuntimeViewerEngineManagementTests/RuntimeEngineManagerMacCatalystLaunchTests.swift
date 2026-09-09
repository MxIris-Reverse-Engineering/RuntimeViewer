#if os(macOS)

import Combine
import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerCommunication
@testable import RuntimeViewerEngineManagement

/// The Mac Catalyst launch: an engine is only offered once its helper has
/// answered, a helper that never answers is reported instead of shown, and a
/// relaunch replaces whatever was there, in flight or not.
///
/// Drives the manager through its ``RuntimeEngineManager/MacCatalystLaunching``
/// seam with stand-in engines, so nothing here reaches the helper daemon or
/// launches a Catalyst process:
///
/// - a **silent** stand-in is a `.macCatalystClient` engine that was never
///   connected — every probe throws, the way a real one does while the helper
///   has not connected back;
/// - an **answering** stand-in is a `.remote` *server* engine: `requestEngineList`
///   answers locally on a non-client source, which is the cheapest deterministic
///   "the peer replied".
@Suite("RuntimeEngineManager Mac Catalyst launch", .serialized)
@MainActor
struct RuntimeEngineManagerMacCatalystLaunchTests {
    private typealias MacCatalystLaunching = RuntimeEngineManager.MacCatalystLaunching

    private static func silentEngine() -> RuntimeEngine {
        RuntimeEngine(source: .macCatalystClient, engineID: "catalyst-launch-tests.silent.\(UUID().uuidString)")
    }

    private static func answeringEngine() -> RuntimeEngine {
        RuntimeEngine(
            source: .remote(name: "Answering stand-in", identifier: "catalyst-launch-tests.answering", role: .server),
            engineID: "catalyst-launch-tests.answering.\(UUID().uuidString)"
        )
    }

    /// A manager that performs none of its startup, so the only engine it
    /// ever holds is the one a test launches.
    private static func makeManager(launching: MacCatalystLaunching) -> RuntimeEngineManager {
        RuntimeEngineManager(configuration: .application, startupHandler: { _ in }, macCatalystLaunching: launching)
    }

    private static func launching(
        engine: @escaping @MainActor () -> RuntimeEngine,
        handshakeTimeout: TimeInterval,
        onLaunchHelper: @escaping @MainActor () -> Void = {}
    ) -> MacCatalystLaunching {
        MacCatalystLaunching(
            makeConnectedEngine: { engine() },
            launchHelper: { onLaunchHelper() },
            terminateHelper: {},
            handshakeTimeout: handshakeTimeout
        )
    }

    private static func macCatalystEngines(of manager: RuntimeEngineManager) -> [RuntimeEngine] {
        manager.systemRuntimeEngines.filter { $0.source == .macCatalystClient }
    }

    /// The defect: a helper that never connects back left an engine in the
    /// menu that loaded forever. Now the engine is withheld and the failure
    /// is reported through the event the notification service listens to.
    @Test("A helper that never answers yields no engine and a catalystHelperUnavailable event")
    func silentHelperIsReportedNotShown() async throws {
        let manager = Self.makeManager(launching: Self.launching(engine: Self.silentEngine, handshakeTimeout: 0.3))
        var events: [RuntimeEngineManagerEvent] = []
        let subscription = manager.eventPublisher.sink { events.append($0) }
        defer { subscription.cancel() }

        manager.relaunchMacCatalystRuntimeEngine()
        await manager.waitForMacCatalystLaunch()

        #expect(Self.macCatalystEngines(of: manager).isEmpty)
        #expect(manager.currentMacCatalystRuntimeEngine == nil)
        let unavailableErrors = events.compactMap { event -> (any Error)? in
            guard case .catalystHelperUnavailable(let error) = event else { return nil }
            return error
        }
        #expect(unavailableErrors.count == 1)
        let error = try #require(unavailableErrors.first as? RuntimeEngineManager.MacCatalystHelperError)
        guard case .handshakeTimedOut = error else {
            Issue.record("expected handshakeTimedOut, got \(error)")
            return
        }
    }

    @Test("A helper that answers yields exactly one engine, appended only after it answered")
    func answeringHelperIsShown() async {
        let manager = Self.makeManager(launching: Self.launching(engine: Self.answeringEngine, handshakeTimeout: 2))
        var events: [RuntimeEngineManagerEvent] = []
        let subscription = manager.eventPublisher.sink { events.append($0) }
        defer { subscription.cancel() }

        manager.relaunchMacCatalystRuntimeEngine()
        await manager.waitForMacCatalystLaunch()

        let engine = manager.currentMacCatalystRuntimeEngine
        #expect(engine != nil)
        #expect(manager.systemRuntimeEngines.count == 1)
        #expect(manager.systemRuntimeEngines.first === engine)
        #expect(!events.contains { if case .catalystHelperUnavailable = $0 { return true } else { return false } })
    }

    /// The daemon-reinstall case: whatever engine was up is torn down and a
    /// fresh helper is asked for, once per relaunch.
    @Test("Relaunching replaces the engine that was up and launches the helper again")
    func relaunchReplacesTheCurrentEngine() async {
        var helperLaunchCount = 0
        let manager = Self.makeManager(launching: Self.launching(
            engine: Self.answeringEngine,
            handshakeTimeout: 2,
            onLaunchHelper: { helperLaunchCount += 1 }
        ))

        manager.relaunchMacCatalystRuntimeEngine()
        await manager.waitForMacCatalystLaunch()
        let firstEngine = manager.currentMacCatalystRuntimeEngine

        manager.relaunchMacCatalystRuntimeEngine()
        await manager.waitForMacCatalystLaunch()
        let secondEngine = manager.currentMacCatalystRuntimeEngine

        #expect(firstEngine != nil)
        #expect(secondEngine != nil)
        #expect(firstEngine !== secondEngine)
        #expect(manager.systemRuntimeEngines.count == 1)
        #expect(manager.systemRuntimeEngines.first === secondEngine)
        #expect(helperLaunchCount == 2)
        if let firstEngine {
            // `terminateRuntimeEngine` stops the engine on a detached task.
            let stopped = await Self.eventually { firstEngine.state.isDisconnected }
            #expect(stopped, "the replaced engine is stopped, not leaked")
        }
    }

    /// Polls `condition` for up to a second.
    private static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 50 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// A relaunch must not wait out a handshake that is still pending: the
    /// daemon was just reinstalled, so that handshake can only time out.
    @Test("Relaunching while a launch is pending cancels it instead of waiting for its timeout")
    func relaunchCancelsThePendingLaunch() async {
        var attempt = 0
        let manager = Self.makeManager(launching: MacCatalystLaunching(
            makeConnectedEngine: {
                attempt += 1
                return attempt == 1 ? Self.silentEngine() : Self.answeringEngine()
            },
            launchHelper: {},
            terminateHelper: {},
            handshakeTimeout: 30
        ))
        var events: [RuntimeEngineManagerEvent] = []
        let subscription = manager.eventPublisher.sink { events.append($0) }
        defer { subscription.cancel() }

        let started = Date()
        manager.relaunchMacCatalystRuntimeEngine()
        // Let the first attempt reach its poll before superseding it.
        try? await Task.sleep(for: .milliseconds(100))
        manager.relaunchMacCatalystRuntimeEngine()
        await manager.waitForMacCatalystLaunch()

        #expect(Date().timeIntervalSince(started) < 5, "the 30 s handshake timeout of the first attempt was not waited out")
        #expect(attempt == 2)
        #expect(manager.currentMacCatalystRuntimeEngine != nil)
        #expect(manager.systemRuntimeEngines.count == 1)
        #expect(!events.contains { if case .catalystHelperUnavailable = $0 { return true } else { return false } },
                "a superseded launch is not a failure")
    }

    @Test("A configuration without system engines ignores relaunch requests")
    func headlessWithoutSystemEnginesIgnoresRelaunch() async {
        var configuration = RuntimeEngineManagerConfiguration.headlessHost
        configuration.launchesSystemEngines = false
        var helperLaunchCount = 0
        let manager = RuntimeEngineManager(
            configuration: configuration,
            startupHandler: { _ in },
            macCatalystLaunching: Self.launching(engine: Self.answeringEngine, handshakeTimeout: 1, onLaunchHelper: { helperLaunchCount += 1 })
        )

        manager.relaunchMacCatalystRuntimeEngine()
        await manager.waitForMacCatalystLaunch()

        #expect(helperLaunchCount == 0)
        #expect(manager.systemRuntimeEngines.isEmpty)
    }
}

extension RuntimeEngine.State {
    fileprivate var isDisconnected: Bool {
        if case .disconnected = self { return true }
        return false
    }
}

#endif
