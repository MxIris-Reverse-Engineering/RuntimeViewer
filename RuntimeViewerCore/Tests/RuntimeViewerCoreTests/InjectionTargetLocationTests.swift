import Testing
import Foundation
import RuntimeViewerCommunication
@testable import RuntimeViewerCore

/// Which side of the attach flow an engine lands on.
///
/// Pinned per source case rather than left to read off the implementation: adding a
/// `RuntimeSource` case puts a new engine on one of these two paths, and getting it wrong
/// is invisible until someone picks a process on the wrong machine. The switch has no
/// `default`, so a new case fails the build — and these tests say what the answer should
/// be once it is added.
@Suite("Injection target location")
struct InjectionTargetLocationTests {
    private static let identifier = RuntimeSource.Identifier(rawValue: "com.RuntimeViewer.tests.injection-target-location")

    private func engine(for source: RuntimeSource) -> RuntimeEngine {
        // Never connected: the property is read off the source, which is exactly the point
        // — the host has to know which path to take before anything is sent.
        RuntimeEngine(source: source)
    }

    // MARK: - This machine

    @Test("The local engine's targets are on this machine")
    func localIsThisMachine() {
        #expect(engine(for: .local).injectionTargetsRunOnThisMachine)
    }

    /// XPC reaches a service inside this app's own bundle and nothing else, so an engine on
    /// the far end of one is by construction on this machine — today the Mac Catalyst helper.
    @Test("An XPC engine's targets are on this machine")
    func xpcIsThisMachine() {
        let source = RuntimeSource.remote(name: "Catalyst", identifier: Self.identifier, role: .client)
        #expect(engine(for: source).injectionTargetsRunOnThisMachine)
    }

    /// A local socket engine is a process Runtime Viewer already injected here — including
    /// one inside the iOS Simulator, which is a host process however iOS it looks.
    @Test("An injected local process's targets are on this machine", arguments: [RuntimeSource.Role.client, .server])
    func localSocketIsThisMachine(role: RuntimeSource.Role) {
        let source = RuntimeSource.localSocket(name: "Injected", identifier: Self.identifier, role: role)
        #expect(engine(for: source).injectionTargetsRunOnThisMachine)
    }

    // MARK: - Another machine

    /// Bonjour is how a device advertises itself. The peer owns its process table, so the
    /// host asks rather than assuming — and must never offer its own processes here.
    @Test("A Bonjour engine's targets are not on this machine", arguments: [RuntimeSource.Role.client, .server])
    func bonjourIsAnotherMachine(role: RuntimeSource.Role) {
        let source = RuntimeSource.bonjour(name: "Someone's iPhone", identifier: Self.identifier, role: role)
        #expect(!engine(for: source).injectionTargetsRunOnThisMachine)
    }

    /// Including over loopback. The address says nothing about whose process table is on
    /// the other end — a mirrored engine reaches a third machine through a second hop.
    @Test("A direct TCP engine's targets are not on this machine", arguments: ["127.0.0.1", "10.0.0.2"])
    func directTCPIsAnotherMachine(host: String) {
        let source = RuntimeSource.directTCP(name: "Mirrored", host: host, port: 50000, role: .client)
        #expect(!engine(for: source).injectionTargetsRunOnThisMachine)
    }

    /// The case this suite's `default`-less switch was waiting for, and the one that
    /// answers the opposite way from the case it most resembles: `injectedTCP` *is*
    /// `localSocket`'s transport and role inversion, with the address unpinned, and the
    /// processes at that address belong to a device.
    @Test(
        "An injected device process's targets are not on this machine",
        arguments: [RuntimeSource.Role.client, .server],
    )
    func injectedTCPIsAnotherMachine(role: RuntimeSource.Role) {
        let source = RuntimeSource.injectedTCP(
            name: "sharingd",
            host: "192.168.64.1",
            port: 51234,
            identifier: Self.identifier,
            role: role,
        )
        #expect(!engine(for: source).injectionTargetsRunOnThisMachine)
    }
}
