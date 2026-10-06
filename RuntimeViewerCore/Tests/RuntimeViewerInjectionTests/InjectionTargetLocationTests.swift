import Testing
import Foundation
import RuntimeViewerCommunication
import RuntimeViewerCore
@testable import RuntimeViewerInjection

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

    /// A local socket engine is a process Runtime Viewer already injected here, one whose
    /// sandbox kept it off XPC.
    @Test("An injected local process's targets are on this machine", arguments: [RuntimeSource.Role.client, .server])
    func localSocketIsThisMachine(role: RuntimeSource.Role) {
        let source = RuntimeSource.localSocket(name: "Injected", identifier: Self.identifier, role: role)
        #expect(engine(for: source).injectionTargetsRunOnThisMachine)
    }

    /// A simulator advertises over Bonjour exactly like a device — the payload injected into a
    /// simulator process, and Runtime Viewer itself running in a simulator — but every process
    /// in it is a process of the Mac running it, already listed by the local picker. Treating
    /// it as another machine asks the simulator, which answers that only the jailbroken build
    /// can attach: Attach greyed out, pointing at a build the user cannot install there.
    @Test("A simulator advertising over Bonjour has its targets on this machine")
    func bonjourSimulatorIsThisMachine() {
        let source = RuntimeSource.bonjour(name: "iPhone 17 Pro", identifier: Self.identifier, role: .client)
        let simulatorHostInfo = RuntimeHostInfo(
            hostID: "4A3E1D0C-7B52-4F1E-9C0A-2D6B8E5F1A93",
            hostName: "iPhone 17 Pro",
            metadata: RuntimeDeviceMetadata(modelIdentifier: "iPhone18,1", osVersion: "27.0", isSimulator: true),
        )
        #expect(RuntimeEngine(source: source, hostInfo: simulatorHostInfo).injectionTargetsRunOnThisMachine)
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
