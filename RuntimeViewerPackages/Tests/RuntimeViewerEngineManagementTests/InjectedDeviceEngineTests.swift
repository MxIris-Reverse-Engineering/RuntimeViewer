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

    // MARK: - Surviving a disconnect

    /// **A link that drops is not the end of an injected device engine, and
    /// treating it as one strands the payload for good.**
    ///
    /// The payload dials one fixed address and port out of its rendezvous and
    /// retries forever; it cannot be told a new one, because re-injecting the
    /// same staged path returns the already-loaded image without running its
    /// constructor again. So tearing the engine down closes the only port it
    /// will ever dial, and the target cannot be attached again until it
    /// restarts — while the host reports the next attempt as a timeout and
    /// blames suspension or a firewall.
    ///
    /// On loopback, where this policy came from, a disconnect did mean the
    /// target was gone. Across a device's Wi-Fi it also means a 25-second
    /// keepalive budget expiring, which is a blip.
    ///
    /// The distinction is the one the transport already reports: a socket
    /// error is the link, and a peer close is the process. A killed process
    /// closes its sockets through the kernel, so `kill -9` arrives here as
    /// `.peerClosed` too — which is why no timer is needed to notice a target
    /// that really died.
    @Test(
        "A dropped link leaves the engine listening for the payload to dial back",
        arguments: [
            RuntimeConnectionError.socketError("recv failed: Operation timed out"),
            .socketError("recv failed: Connection reset by peer"),
            .timeout,
            .networkError("the interface went away"),
        ],
    )
    func aDroppedLinkDoesNotFinishAnInjectedEngine(error: RuntimeConnectionError) {
        #expect(!RuntimeEngineManager.injectedDeviceEngineIsFinished(afterDisconnectWith: error))
    }

    /// The other half: the cases that really are the end of it, so the row does
    /// not linger and the device is told it may suspend the target again.
    @Test("The payload's process going away finishes the engine")
    func aClosedPeerFinishesAnInjectedEngine() {
        // The payload closed its socket: its process exited, or was killed and
        // the kernel closed them for it.
        #expect(RuntimeEngineManager.injectedDeviceEngineIsFinished(afterDisconnectWith: .peerClosed))
        // No error at all is this side's own `stop()` — the detach path.
        #expect(RuntimeEngineManager.injectedDeviceEngineIsFinished(afterDisconnectWith: nil))
    }

    /// **What the injection took, and when it is given back.**
    ///
    /// The device holds a RunningBoard assertion on the target for as long as
    /// the engine lives, because an injected target that backgrounds would
    /// otherwise be suspended mid-inspection. Hanging its release off every
    /// teardown released it on a blip as well — and since the hold is what
    /// keeps the target inspectable, that is the one teardown where it must be
    /// kept.
    @Test("The hold is given back when the injection ends, and kept across a blip")
    func theHoldOutlivesABlipButNotTheInjection() {
        // The user detached, or an attach failed and is rolling back.
        #expect(RuntimeEngineManager.releasesKeepAwakeHold(onTerminationBecause: .requested))
        // The target's payload is gone, so nothing needs it awake.
        #expect(RuntimeEngineManager.releasesKeepAwakeHold(onTerminationBecause: .connectionLost(.peerClosed)))
        // The link dropped. The target is still being inspected.
        #expect(!RuntimeEngineManager.releasesKeepAwakeHold(onTerminationBecause: .connectionLost(.timeout)))
        // The payload advertised itself instead of dialling, so the listener is
        // dropped — but the engine that won the race is inspecting the very
        // process whose hold this is. Releasing here suspends the target the
        // user just attached to.
        #expect(!RuntimeEngineManager.releasesKeepAwakeHold(onTerminationBecause: .supersededByAdvertisement))
    }
}

/// The dropped-link case end to end, through a real listener and a real socket.
///
/// The predicates above say what the manager *decides*; this says what actually
/// happens to the listener, which is the half that strands a target when it goes
/// wrong. It is driven with a bare socket rather than a second engine because
/// what the payload does here is not an engine's behaviour — it dials, gets
/// reset, and dials again.
@Suite("Injected device engine reconnection")
@MainActor
struct InjectedDeviceEngineReconnectionTests {
    /// Everything off: no Bonjour, no system engines, no reconnection pass. The
    /// listener under test is the only thing this manager brings up.
    private static let inertConfiguration = RuntimeEngineManagerConfiguration(
        advertisesOverBonjour: false,
        sharesEnginesWithPeers: false,
        launchesSystemEngines: false,
        reconnectsInjectedEngines: false,
    )

    private static let deviceHostInfo = RuntimeHostInfo(
        hostID: "20DAFF33-83CA-4C2F-AD0E-809B05501803",
        hostName: "jhs-iphone",
    )

    /// Dials the host's listener the way a payload does, and can vanish the way
    /// a dropped link does.
    private struct PayloadSocket: ~Copyable {
        let fileDescriptor: Int32

        init(port: UInt16) throws {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            try #require(descriptor >= 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            try #require(inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1)
            let connected = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else {
                close(descriptor)
                throw PayloadSocketError.refused(errorNumber: errno)
            }
            fileDescriptor = descriptor
        }

        /// Closes with a zero linger, which sends RST rather than FIN — the
        /// shape a lost link has, and the one the fix turns on. A plain close
        /// would be `peerClosed`, which *should* finish the engine.
        consuming func reset() {
            var linger = linger(l_onoff: 1, l_linger: 0)
            setsockopt(fileDescriptor, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
            close(fileDescriptor)
        }

        deinit { close(fileDescriptor) }
    }

    private enum PayloadSocketError: Error {
        case refused(errorNumber: Int32)
    }

    /// **The regression this exists for.** The payload dials one port forever
    /// and cannot be handed another, so the listener has to survive a reset:
    /// before the fix it was closed, and every later attach reported injection
    /// success and then timed out until the target restarted.
    @Test("A reset leaves the listener up, and the payload's next dial is accepted")
    func listenerSurvivesAResetAndAcceptsTheNextDial() async throws {
        let manager = RuntimeEngineManager(configuration: Self.inertConfiguration, startupHandler: { _ in })
        let deviceEngine = RuntimeEngine(source: .bonjour(
            name: "RuntimeViewer",
            identifier: .init(rawValue: Self.deviceHostInfo.hostID),
            role: .client,
        ), hostInfo: Self.deviceHostInfo)

        let rendezvous = RuntimePayloadRendezvous(
            hostAddress: "127.0.0.1",
            hostPort: try RuntimeUnusedPort.find(),
            claimToken: "RECONNECTION-TEST-TOKEN",
        )
        let injectedEngine = try await manager.launchInjectedDeviceEngine(
            name: "sharingd",
            rendezvous: rendezvous,
            deviceHostInfo: Self.deviceHostInfo,
            deviceIdentifier: Self.deviceHostInfo.hostID,
            deviceEngine: deviceEngine,
            processIdentifier: 346,
        )
        defer { manager.terminateRuntimeEngine(for: injectedEngine.source) }

        // The payload arrives, then its link dies without a FIN.
        let firstDial = try PayloadSocket(port: rendezvous.hostPort)
        try await waitUntil { injectedEngine.state == .connected }
        firstDial.reset()

        // That the reset was noticed at all, before anything is concluded from
        // what survived it. The engine does not *rest* in `.disconnected`: the
        // socket server re-arms `accept()` in the same turn that reports the
        // disconnect, so `.connecting` follows immediately and the intermediate
        // state is not reliably observable — measured, by sampling it.
        try await waitUntil { injectedEngine.state != .connected }

        // Still listed: the device is still there and its payload is redialling.
        #expect(manager.runtimeEngines.contains { $0 === injectedEngine })

        // And the port it will dial is still open. Before the fix the engine was
        // gone from the list by now and this dial got ECONNREFUSED — the
        // listener had been closed for the life of the target.
        let secondDial = try await dialWithRetries(port: rendezvous.hostPort)
        try await waitUntil { injectedEngine.state == .connected }
        secondDial.reset()
    }

    /// The listener re-arms a moment after the reset is noticed, so a single
    /// dial can lose a race that says nothing about the fix.
    private func dialWithRetries(
        port: UInt16,
        within timeout: TimeInterval = 5,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) async throws -> PayloadSocket {
        let deadline = Date().addingTimeInterval(timeout)
        var lastErrorNumber: Int32 = 0
        while Date() < deadline {
            do {
                return try PayloadSocket(port: port)
            } catch PayloadSocketError.refused(let errorNumber) {
                lastErrorNumber = errorNumber
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        Issue.record(
            "the payload's redial was still refused after \(timeout)s (errno \(lastErrorNumber)): the listener did not survive the reset",
            sourceLocation: sourceLocation,
        )
        throw PayloadSocketError.refused(errorNumber: lastErrorNumber)
    }

    /// The other half, so the fix cannot have been "never tear down": a payload
    /// whose process exits closes its socket properly, and that does finish the
    /// engine.
    @Test("A payload that closes cleanly finishes the engine")
    func aCleanCloseRemovesTheEngine() async throws {
        let manager = RuntimeEngineManager(configuration: Self.inertConfiguration, startupHandler: { _ in })
        let deviceEngine = RuntimeEngine(source: .bonjour(
            name: "RuntimeViewer",
            identifier: .init(rawValue: Self.deviceHostInfo.hostID),
            role: .client,
        ), hostInfo: Self.deviceHostInfo)

        let rendezvous = RuntimePayloadRendezvous(
            hostAddress: "127.0.0.1",
            hostPort: try RuntimeUnusedPort.find(),
            claimToken: "CLEAN-CLOSE-TEST-TOKEN",
        )
        let injectedEngine = try await manager.launchInjectedDeviceEngine(
            name: "sharingd",
            rendezvous: rendezvous,
            deviceHostInfo: Self.deviceHostInfo,
            deviceIdentifier: Self.deviceHostInfo.hostID,
            deviceEngine: deviceEngine,
            processIdentifier: 347,
        )

        let dial = try PayloadSocket(port: rendezvous.hostPort)
        try await waitUntil { injectedEngine.state == .connected }
        // No linger: a FIN, which is what a process exiting sends.
        close(dial.fileDescriptor)
        _ = consume dial

        try await waitUntil { !manager.runtimeEngines.contains { $0 === injectedEngine } }
    }

    private func waitUntil(
        _ condition: () -> Bool,
        within timeout: TimeInterval = 5,
        sourceLocation: SourceLocation = #_sourceLocation,
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("condition still false after \(timeout)s", sourceLocation: sourceLocation)
    }
}
