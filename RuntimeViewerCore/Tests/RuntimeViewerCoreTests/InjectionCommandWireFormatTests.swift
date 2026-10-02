import Testing
import Foundation
@testable import RuntimeViewerCore

/// The three injection commands and their payloads are a cross-process contract:
/// the peer that encodes them is a different build — on iOS, a different *app* —
/// from the one that decodes them. So these tests pin the encoded form, not just
/// that a round trip happens to work in one process.
@Suite("Injection command wire format")
struct InjectionCommandWireFormatTests {
    // MARK: - Command names

    /// The command name is what the peer matches on. Renaming a `CommandNames`
    /// case silently renames the wire name with it, and a peer built before the
    /// rename then has no handler — a failure that only shows up between two
    /// different builds, which no single-process test would catch.
    @Test("Command names are the documented strings")
    func commandNames() {
        let prefix = "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine."
        #expect(RuntimeEngine.CommandNames.injectionCapability.commandName == prefix + "injectionCapability")
        #expect(RuntimeEngine.CommandNames.processList.commandName == prefix + "processList")
        #expect(RuntimeEngine.CommandNames.injectIntoProcess.commandName == prefix + "injectIntoProcess")
    }

    @Test("Every command name is unique")
    func commandNamesAreUnique() {
        let names = RuntimeEngine.CommandNames.allCases.map(\.commandName)
        #expect(Set(names).count == names.count)
    }

    /// The request types' `commandName` must be the matching case, or a request
    /// would be dispatched under a name nobody registered a handler for.
    @Test("Request types name their own command")
    func requestTypesNameTheirCommand() {
        #expect(RuntimeEngine.InjectionCapabilityRequest.commandName == RuntimeEngine.CommandNames.injectionCapability.commandName)
        #expect(RuntimeEngine.ProcessListRequest.commandName == RuntimeEngine.CommandNames.processList.commandName)
        #expect(RuntimeEngine.InjectIntoProcessRequest.commandName == RuntimeEngine.CommandNames.injectIntoProcess.commandName)
    }

    // MARK: - Round trips

    @Test("RuntimeInjectionAvailability survives a round trip", arguments: [
        RuntimeInjectionAvailability.available,
        .requiresJailbrokenVariant,
        .helperDaemonNotInstalled,
        .unsupported(reason: "Runtime Viewer does not implement process injection on this platform."),
    ])
    func availabilityRoundTrip(_ availability: RuntimeInjectionAvailability) throws {
        let decoded = try roundTrip(availability)
        #expect(decoded == availability)
    }

    @Test("RuntimeProcess.Injectability survives a round trip", arguments: [
        RuntimeProcess.Injectability.injectable,
        .requiresRootOnTarget,
        .notInjectable(reason: "Executable could not be read."),
    ])
    func injectabilityRoundTrip(_ injectability: RuntimeProcess.Injectability) throws {
        let decoded = try roundTrip(injectability)
        #expect(decoded == injectability)
    }

    @Test("RuntimeProcessInjectionResult survives a round trip", arguments: [
        RuntimeProcessInjectionResult.injected,
        .taskPortUnavailable(reason: "task_for_pid was refused."),
        .targetRefusedPayload(reason: "code signature invalid"),
        .failed(code: 16, reason: "thread_create_running failed"),
    ])
    func injectionResultRoundTrip(_ result: RuntimeProcessInjectionResult) throws {
        let decoded = try roundTrip(result)
        #expect(decoded == result)
    }

    /// `executablePath` and `userIdentifier` are both deliberately optional —
    /// "could not read it" is a real state for a live process — so every
    /// combination has to survive the wire. A `nil` that decoded as a zero
    /// would be the worst possible failure here: uid 0 is precisely the value
    /// that means "root target, needs root to inject".
    @Test("RuntimeProcess survives a round trip with either optional absent")
    func processRoundTrip() throws {
        let complete = RuntimeProcess(
            processIdentifier: 4321,
            name: "backboardd",
            executablePath: "/usr/libexec/backboardd",
            userIdentifier: 501,
            injectability: .injectable,
        )
        let rootOwned = RuntimeProcess(
            processIdentifier: 1,
            name: "launchd",
            executablePath: nil,
            userIdentifier: 0,
            injectability: .requiresRootOnTarget,
        )
        let unknownOwner = RuntimeProcess(
            processIdentifier: 77,
            name: "opaque",
            executablePath: nil,
            userIdentifier: nil,
            injectability: .injectable,
        )
        #expect(try roundTrip(complete) == complete)
        #expect(try roundTrip(rootOwned) == rootOwned)
        #expect(try roundTrip(unknownOwner) == unknownOwner)

        // The distinction that matters, asserted rather than assumed.
        #expect(try roundTrip(unknownOwner).userIdentifier == nil)
        #expect(try roundTrip(rootOwned).userIdentifier == 0)
    }

    @Test("A process list survives a round trip as the response type it is")
    func processListRoundTrip() throws {
        let processes = [
            RuntimeProcess(processIdentifier: 1, name: "launchd", executablePath: "/sbin/launchd", userIdentifier: 0, injectability: .requiresRootOnTarget),
            RuntimeProcess(processIdentifier: 988, name: "SpringBoard", executablePath: nil, userIdentifier: 501, injectability: .injectable),
        ]
        #expect(try roundTrip(processes) == processes)
    }

    /// Not routed through `roundTrip(_:)`: the request type is not `Equatable`,
    /// and giving it a conformance only tests could use would be the test
    /// shaping the API.
    @Test("InjectIntoProcessRequest carries its pid and rendezvous across the wire")
    func injectRequestRoundTrip() throws {
        let rendezvous = RuntimePayloadRendezvous(
            hostAddress: "192.168.64.1",
            hostPort: 51234,
            claimToken: "06A9F1C2-1C1B-4A9E-9C2E-7E6A2F0D3B41",
        )
        let encoded = try JSONEncoder().encode(
            RuntimeEngine.InjectIntoProcessRequest(processIdentifier: 31337, rendezvous: rendezvous)
        )
        let decoded = try JSONDecoder().decode(RuntimeEngine.InjectIntoProcessRequest.self, from: encoded)
        #expect(decoded.processIdentifier == 31337)
        #expect(decoded.rendezvous == rendezvous)
    }

    // MARK: - The rendezvous

    @Test("RuntimePayloadRendezvous survives a round trip")
    func rendezvousRoundTrip() throws {
        let rendezvous = RuntimePayloadRendezvous(
            hostAddress: "192.168.64.1",
            hostPort: 51234,
            claimToken: RuntimePayloadRendezvous.makeClaimToken(),
        )
        #expect(try roundTrip(rendezvous) == rendezvous)
    }

    /// The encoded keys are a contract between two *different builds*: the host
    /// writes this file and a payload compiled separately — on a device, from a
    /// separately installed app — reads it. Renaming a property would rename the
    /// key with it and the payload would decode nothing, so the names are pinned
    /// here rather than left to whatever the synthesized coder happens to emit.
    @Test("The rendezvous encodes under the documented keys")
    func rendezvousEncodedKeys() throws {
        let encoded = try JSONEncoder().encode(
            RuntimePayloadRendezvous(hostAddress: "10.0.0.2", hostPort: 9, claimToken: "token")
        )
        let fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(fields.keys) == ["hostAddress", "hostPort", "claimToken"])
        #expect(fields["hostAddress"] as? String == "10.0.0.2")
        #expect(fields["hostPort"] as? Int == 9)
        #expect(fields["claimToken"] as? String == "token")
    }

    /// The compatibility path, and the one worth a test of its own: an injector
    /// built before the rendezvous existed sends a request with no such key.
    /// That has to decode as "no rendezvous" — the payload then advertises
    /// itself, which is what it does today — rather than failing the decode and
    /// turning an older peer into a broken one.
    @Test("A request without the rendezvous key decodes as having none")
    func injectRequestFromAnOlderPeer() throws {
        let legacyEncoding = Data(#"{"processIdentifier":4321}"#.utf8)
        let decoded = try JSONDecoder().decode(RuntimeEngine.InjectIntoProcessRequest.self, from: legacyEncoding)
        #expect(decoded.processIdentifier == 4321)
        #expect(decoded.rendezvous == nil)
    }

    /// The other direction of the same compatibility story. A peer built before
    /// this change decodes by key, so an absent key costs nothing — but a key
    /// present and null would reach the simulator's own payload too, and the
    /// contract is cleaner if "no rendezvous" is literally no key.
    @Test("A nil rendezvous is omitted from the encoding, not encoded as null")
    func nilRendezvousIsOmitted() throws {
        let encoded = try JSONEncoder().encode(
            RuntimeEngine.InjectIntoProcessRequest(processIdentifier: 4321, rendezvous: nil)
        )
        let fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["rendezvous"] == nil)
        #expect(Set(fields.keys) == ["processIdentifier"])
    }

    /// `isUsable` is what the payload checks before abandoning the advertising
    /// path. Reading a half-filled rendezvous as usable is the one failure with
    /// no symptom: the payload would neither advertise nor connect, and the only
    /// evidence would be a target that goes quiet.
    @Test("A rendezvous missing any of its three parts is not usable")
    func rendezvousUsability() {
        let complete = RuntimePayloadRendezvous(hostAddress: "10.0.0.2", hostPort: 51234, claimToken: "token")
        #expect(complete.isUsable)
        #expect(!RuntimePayloadRendezvous(hostAddress: "", hostPort: 51234, claimToken: "token").isUsable)
        #expect(!RuntimePayloadRendezvous(hostAddress: "10.0.0.2", hostPort: 0, claimToken: "token").isUsable)
        #expect(!RuntimePayloadRendezvous(hostAddress: "10.0.0.2", hostPort: 51234, claimToken: "").isUsable)
    }

    /// One token per injection, so two injections in flight at once cannot have
    /// the first arrival claimed by the wrong request.
    @Test("Each claim token is new")
    func claimTokensAreDistinct() {
        let tokens = (0 ..< 64).map { _ in RuntimePayloadRendezvous.makeClaimToken() }
        #expect(Set(tokens).count == tokens.count)
        #expect(tokens.allSatisfy { !$0.isEmpty })
    }

    /// An engine with no network connection under it cannot say how a peer would
    /// reach this process, and the answer has to be a refusal rather than a
    /// plausible-looking address. Injecting against a guessed address produces a
    /// payload dialling nowhere and a user watching a target that never
    /// appears — a far worse failure than being told up front.
    @Test("A rendezvous is refused for an engine that cannot say how to reach us")
    func rendezvousNeedsAReachableAddress() async {
        // `.local` never has a connection, which is the cheapest engine that
        // genuinely cannot answer; nothing is started here.
        let engine = RuntimeEngine(source: .local)
        await #expect(throws: RuntimePayloadRendezvous.Unavailable.self) {
            _ = try await RuntimePayloadRendezvous.reachingThisProcess(from: engine)
        }
    }

    /// The refusal is read by a user, so it has to say what could not be worked
    /// out rather than name a property.
    @Test("The refusal names the engine and explains what is missing")
    func rendezvousRefusalIsReadable() throws {
        let message = try #require(
            RuntimePayloadRendezvous.Unavailable
                .peerCannotReachThisProcess(engineName: "Someone's iPhone")
                .errorDescription
        )
        #expect(message.contains("Someone's iPhone"))
        #expect(message.lowercased().contains("address"))
    }

    // MARK: - Convenience predicates

    /// These drive a toolbar item's enabled state and a row's selectability, so
    /// a case added later that falls into the wrong branch would quietly offer
    /// an action that cannot work.
    @Test("isAvailable is true for exactly the available case")
    func availabilityPredicate() {
        #expect(RuntimeInjectionAvailability.available.isAvailable)
        #expect(!RuntimeInjectionAvailability.requiresJailbrokenVariant.isAvailable)
        #expect(!RuntimeInjectionAvailability.helperDaemonNotInstalled.isAvailable)
        #expect(!RuntimeInjectionAvailability.unsupported(reason: "no").isAvailable)
    }

    @Test("isInjectable is true for exactly the injectable case")
    func injectabilityPredicate() {
        #expect(RuntimeProcess.Injectability.injectable.isInjectable)
        #expect(!RuntimeProcess.Injectability.requiresRootOnTarget.isInjectable)
        #expect(!RuntimeProcess.Injectability.notInjectable(reason: "no").isInjectable)
    }

    @Test("isInjected is true for exactly the injected case")
    func injectionResultPredicate() {
        #expect(RuntimeProcessInjectionResult.injected.isInjected)
        #expect(!RuntimeProcessInjectionResult.taskPortUnavailable(reason: "no").isInjected)
        #expect(!RuntimeProcessInjectionResult.targetRefusedPayload(reason: "no").isInjected)
        #expect(!RuntimeProcessInjectionResult.failed(code: 3, reason: "no").isInjected)
    }

    // MARK: - The no-service default

    /// What a process with no registered service answers, per platform.
    ///
    /// The macOS assertion is the point of this test. On macOS the app always
    /// registers a service, and that service reports
    /// `helperDaemonNotInstalled` itself when the daemon is missing — so
    /// reaching this value means nobody wired the service up. Answering
    /// `helperDaemonNotInstalled` there would send the user to reinstall a
    /// daemon whose absence is not the problem, so the default must *not* be
    /// that case.
    @Test("withoutInjectionService answers the platform's honest default")
    func withoutInjectionServiceDefault() {
        let availability = RuntimeInjectionAvailability.withoutInjectionService
        #expect(!availability.isAvailable)

        #if os(macOS) || targetEnvironment(macCatalyst)
        if case .unsupported = availability {} else {
            Issue.record("Expected .unsupported on macOS, got \(availability)")
        }
        #expect(availability != .helperDaemonNotInstalled)
        #elseif os(iOS)
        #expect(availability == .requiresJailbrokenVariant)
        #else
        if case .unsupported = availability {} else {
            Issue.record("Expected .unsupported on this platform, got \(availability)")
        }
        #endif
    }

    // MARK: -

    private func roundTrip<Value: Codable & Equatable>(_ value: Value) throws -> Value {
        let encoded = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(Value.self, from: encoded)
    }
}
