#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerEngineManagement

/// Contract suite for what a `RuntimeEngineManagerConfiguration` makes the
/// manager bring up.
///
/// Goes through the manager's own initializer with the startup seam engaged,
/// so it is the initializer's reading of the configuration under test — not a
/// copy of the mapping — while nothing here starts Bonjour or reaches the
/// helper daemon.
@Suite("RuntimeEngineManagerConfiguration")
@MainActor
struct RuntimeEngineManagerConfigurationTests {
    private typealias StartupStep = RuntimeEngineManagerConfiguration.StartupStep

    private func startupSteps(for configuration: RuntimeEngineManagerConfiguration) -> [StartupStep] {
        var performed: [StartupStep] = []
        _ = RuntimeEngineManager(configuration: configuration) { performed.append($0) }
        return performed
    }

    @Test("The application configuration brings everything up, Bonjour server before browser")
    func applicationStartsEverything() {
        #expect(startupSteps(for: .application) == [
            .bonjourServer,
            .bonjourBrowser,
            .systemEngines,
            .injectedEngineReconnection,
            .engineSharing,
        ])
    }

    @Test("The headless host neither advertises nor shares, but still browses and attaches")
    func headlessHostSkipsAdvertisingAndSharing() {
        #expect(startupSteps(for: .headlessHost) == [
            .bonjourBrowser,
            .systemEngines,
            .injectedEngineReconnection,
        ])
    }

    @Test("Each switch controls exactly its own step, and browsing is never optional", arguments: 0 ..< 16)
    func eachSwitchMapsToItsStep(bitmask: Int) {
        let configuration = RuntimeEngineManagerConfiguration(
            advertisesOverBonjour: bitmask & 0b0001 != 0,
            sharesEnginesWithPeers: bitmask & 0b0010 != 0,
            launchesSystemEngines: bitmask & 0b0100 != 0,
            reconnectsInjectedEngines: bitmask & 0b1000 != 0
        )
        let steps = startupSteps(for: configuration)

        #expect(steps.contains(.bonjourBrowser))
        #expect(steps.contains(.bonjourServer) == configuration.advertisesOverBonjour)
        #expect(steps.contains(.engineSharing) == configuration.sharesEnginesWithPeers)
        #expect(steps.contains(.systemEngines) == configuration.launchesSystemEngines)
        #expect(steps.contains(.injectedEngineReconnection) == configuration.reconnectsInjectedEngines)
        #expect(Set(steps).count == steps.count, "no step is scheduled twice")
    }

    @Test("The Bonjour server, when on, is scheduled before the browser")
    func serverPrecedesBrowser() {
        let steps = startupSteps(for: .application)
        let serverIndex = try! #require(steps.firstIndex(of: .bonjourServer))
        let browserIndex = try! #require(steps.firstIndex(of: .bonjourBrowser))
        #expect(serverIndex < browserIndex)
    }
}

#endif
