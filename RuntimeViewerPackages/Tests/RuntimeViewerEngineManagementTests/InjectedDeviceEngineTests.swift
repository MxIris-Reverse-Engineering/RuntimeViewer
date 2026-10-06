import Testing
import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerInjection
@testable import RuntimeViewerEngineManagement

/// The host's half of the reverse-connection path: the source it listens on,
/// and what it tells the user when nothing arrives.
///
/// Background: `Documentations/Evolutions/draft-device-payload-reverse-connection.md`.
@Suite("Injected device engines")
@MainActor
struct InjectedDeviceEngineTests {
    private let rendezvous = RuntimePayloadRendezvous(
        hostAddress: "192.168.64.1",
        hostPort: 51234,
        claimToken: "06A9F1C2-1C1B-4A9E-9C2E-7E6A2F0D3B41",
    )

    // MARK: - The source

    /// Business **client**, which is the counter-intuitive half. This side asks
    /// the questions and this side listens, because the side that answers them
    /// is a payload whose target sandbox will not let it bind.
    @Test("The host listens as the business client, on the address it published")
    func sourceIsTheBusinessClientOnThePublishedAddress() {
        let source = RuntimeEngineManager.injectedDeviceSource(name: "sharingd", rendezvous: rendezvous)
        guard case .injectedTCP(let name, let host, let port, let identifier, let role) = source else {
            Issue.record("Expected an injectedTCP source, got \(source)")
            return
        }
        #expect(name == "sharingd")
        #expect(host == rendezvous.hostAddress)
        #expect(port == rendezvous.hostPort)
        #expect(identifier.rawValue == rendezvous.claimToken)
        #expect(role == .client)
    }

    /// Both ends have to agree on the port, and they agree by it coming from the
    /// rendezvous rather than from the identifier hash `localSocket` uses — the
    /// host is listening before the payload exists, so it cannot be told one.
    @Test("Two injections into the same process get different sources")
    func eachInjectionGetsItsOwnSource() {
        let first = RuntimeEngineManager.injectedDeviceSource(name: "sharingd", rendezvous: rendezvous)
        let second = RuntimeEngineManager.injectedDeviceSource(
            name: "sharingd",
            rendezvous: RuntimePayloadRendezvous(
                hostAddress: rendezvous.hostAddress,
                hostPort: 51235,
                claimToken: "A-SECOND-TOKEN",
            ),
        )
        #expect(first != second)
    }

    // MARK: - Whose process it is

    private static let deviceHostInfo = RuntimeHostInfo(
        hostID: "20DAFF33-83CA-4C2F-AD0E-809B05501803",
        hostName: "jhs-iphone",
    )

    private func engine(name: String = "searchpartyd", rendezvous: RuntimePayloadRendezvous? = nil) -> RuntimeEngine {
        RuntimeEngineManager.makeInjectedDeviceEngine(
            name: name,
            rendezvous: rendezvous ?? self.rendezvous,
            deviceHostInfo: Self.deviceHostInfo,
            deviceIdentifier: Self.deviceHostInfo.hostID,
        )
    }

    /// The engine list is grouped by host identity, and this engine is built on
    /// this Mac for a process that is not on it. Measured: without the device's
    /// identity it inherited this machine's and `searchpartyd` was listed under
    /// "JH's Mac Studio Ultra", beside the Mac's own processes.
    @Test("An injected device process belongs to the device, not to this Mac")
    func engineCarriesTheDevicesIdentity() {
        let engine = engine()
        #expect(engine.hostInfo.hostID == Self.deviceHostInfo.hostID)
        #expect(engine.hostInfo.hostName == "jhs-iphone")
        // The default `RuntimeEngine` host identity is this machine's, which is
        // exactly what this engine used to inherit.
        #expect(engine.hostInfo.hostID != RuntimeNetworkBonjour.localInstanceID)
    }

    /// Bookmarks are filed by scope, and the claim token changes on every
    /// injection. Scoping by it would quietly lose a process's bookmarks each
    /// time it was re-injected — so the scope is the process on the device,
    /// which is also exactly what the same process gets when its payload
    /// advertises itself instead.
    @Test("Its bookmark scope survives a re-injection")
    func bookmarkScopeIsStableAcrossInjections() {
        let first = engine()
        let second = engine(rendezvous: RuntimePayloadRendezvous(
            hostAddress: "169.254.153.160",
            hostPort: 59000,
            claimToken: RuntimePayloadRendezvous.makeClaimToken(),
        ))
        #expect(first.bookmarkScope == second.bookmarkScope)
        #expect(first.bookmarkScope == .identified(.bonjour(
            deviceID: Self.deviceHostInfo.hostID,
            processName: "searchpartyd",
            role: .client,
        )))
    }

    /// Two processes on one device are two entries, not one.
    @Test("Two processes on the same device keep separate scopes")
    func twoProcessesOnOneDeviceStayApart() {
        #expect(engine(name: "searchpartyd").bookmarkScope != engine(name: "dasd").bookmarkScope)
    }

    // MARK: - What the user is told

    /// The message this case exists for. Before the device path had one of its
    /// own, a device timeout reported the *simulator* message — which blames an
    /// advertisement a device payload does not make and sends the reader to
    /// `xcrun simctl`, a command that has nothing to do with a phone.
    @Test("A device timeout does not reuse the simulator's explanation")
    func deviceTimeoutHasItsOwnExplanation() throws {
        let message = try #require(
            RuntimeEngineManager.AttachedEngineHandshakeError
                .injectedDeviceEngineNeverReportedIn(name: "sharingd", processIdentifier: 346)
                .errorDescription
        )
        #expect(message.contains("sharingd"))
        #expect(message.contains("346"))
        #expect(!message.contains("simctl"))
        #expect(!message.lowercased().contains("simulator"))
        // The two causes measured on a device, both of which the user can act on.
        #expect(message.lowercased().contains("suspended"))
        #expect(message.lowercased().contains("firewall"))
    }

    /// The simulator's message is still the simulator's. Changing the device
    /// path must not have taken the `simctl` pointer away from the one platform
    /// where it is the right advice.
    @Test("The simulator's explanation still points at simctl")
    func simulatorTimeoutStillPointsAtSimctl() throws {
        let message = try #require(
            RuntimeEngineManager.AttachedEngineHandshakeError
                .bonjourEngineNeverAdvertised(name: "SpringBoard", processIdentifier: 77)
                .errorDescription
        )
        #expect(message.contains("simctl"))
    }
}
