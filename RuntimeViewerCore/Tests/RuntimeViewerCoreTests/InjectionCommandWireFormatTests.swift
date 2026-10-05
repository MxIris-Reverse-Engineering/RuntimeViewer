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
        #expect(RuntimeEngine.CommandNames.applicationIcons.commandName == prefix + "applicationIcons")
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
        #expect(RuntimeEngine.ApplicationIconsRequest.commandName == RuntimeEngine.CommandNames.applicationIcons.commandName)
        #expect(RuntimeEngine.InjectIntoProcessRequest.commandName == RuntimeEngine.CommandNames.injectIntoProcess.commandName)
        #expect(RuntimeEngine.StopKeepingProcessAwakeRequest.commandName == RuntimeEngine.CommandNames.stopKeepingProcessAwake.commandName)
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

    /// `executablePath`, `userIdentifier` and `applicationBundlePath` are all
    /// deliberately optional — "could not read it" is a real state for a live
    /// process, and "belongs to no application bundle" is the state of nearly
    /// every one — so every combination has to survive the wire. A `nil` that
    /// decoded as a zero would be the worst possible failure here: uid 0 is
    /// precisely the value that means "root target, needs root to inject".
    @Test("RuntimeProcess survives a round trip with any optional absent")
    func processRoundTrip() throws {
        let complete = RuntimeProcess(
            processIdentifier: 4321,
            name: "backboardd",
            executablePath: "/usr/libexec/backboardd",
            userIdentifier: 501,
            applicationBundlePath: nil,
            injectability: .injectable,
        )
        let rootOwned = RuntimeProcess(
            processIdentifier: 1,
            name: "launchd",
            executablePath: nil,
            userIdentifier: 0,
            applicationBundlePath: nil,
            injectability: .requiresRootOnTarget,
        )
        let unknownOwner = RuntimeProcess(
            processIdentifier: 77,
            name: "opaque",
            executablePath: nil,
            userIdentifier: nil,
            applicationBundlePath: nil,
            injectability: .injectable,
        )
        let bundled = RuntimeProcess(
            processIdentifier: 988,
            name: "MobileSafari",
            executablePath: "/Applications/MobileSafari.app/MobileSafari",
            userIdentifier: 501,
            applicationBundlePath: "/Applications/MobileSafari.app",
            injectability: .injectable,
        )
        #expect(try roundTrip(bundled) == bundled)
        #expect(try roundTrip(bundled).applicationBundlePath == "/Applications/MobileSafari.app")
        #expect(try roundTrip(complete).applicationBundlePath == nil)
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
            RuntimeProcess(processIdentifier: 1, name: "launchd", executablePath: "/sbin/launchd", userIdentifier: 0, applicationBundlePath: nil, injectability: .requiresRootOnTarget),
            RuntimeProcess(processIdentifier: 988, name: "SpringBoard", executablePath: nil, userIdentifier: 501, applicationBundlePath: nil, injectability: .injectable),
        ]
        #expect(try roundTrip(processes) == processes)
    }

    // MARK: - Application icons

    /// The compatibility direction that matters for the icons: a device build
    /// made before application bundles were reported sends a process with no
    /// such key. That has to decode as "this process has no bundle" — the host
    /// then asks for no icon and shows the generic one — rather than failing
    /// the decode and taking the whole process list down with it.
    @Test("A process without the application bundle key decodes as having none")
    func processFromAnOlderPeerHasNoApplicationBundle() throws {
        let legacyEncoding = Data(#"""
        {"processIdentifier":988,"name":"SpringBoard","executablePath":"/Applications/SpringBoard.app/SpringBoard","userIdentifier":501,"injectability":{"injectable":{}}}
        """#.utf8)
        let decoded = try JSONDecoder().decode(RuntimeProcess.self, from: legacyEncoding)
        #expect(decoded.processIdentifier == 988)
        #expect(decoded.applicationBundlePath == nil)
        #expect(decoded.injectability == .injectable)
    }

    /// The other direction of the same story: a `nil` bundle path has to be
    /// *absent* from the encoding rather than encoded as null, so that a peer
    /// built before this change decodes the list unchanged.
    @Test("A nil application bundle path is omitted from the encoding")
    func nilApplicationBundlePathIsOmitted() throws {
        let encoded = try JSONEncoder().encode(
            RuntimeProcess(
                processIdentifier: 42,
                name: "mediaserverd",
                executablePath: "/usr/sbin/mediaserverd",
                userIdentifier: 501,
                applicationBundlePath: nil,
                injectability: .injectable,
            )
        )
        let fields = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(fields["applicationBundlePath"] == nil)
    }

    /// Not routed through `roundTrip(_:)`: the request type is not `Equatable`,
    /// and giving it a conformance only tests could use would be the test
    /// shaping the API.
    @Test("ApplicationIconsRequest carries its bundle paths across the wire")
    func applicationIconsRequestRoundTrip() throws {
        let paths = ["/Applications/MobileSafari.app", "/Applications/Preferences.app"]
        let encoded = try JSONEncoder().encode(
            RuntimeEngine.ApplicationIconsRequest(applicationBundlePaths: paths)
        )
        let decoded = try JSONDecoder().decode(RuntimeEngine.ApplicationIconsRequest.self, from: encoded)
        #expect(decoded.applicationBundlePaths == paths)
    }

    /// The response is PNG bytes keyed by bundle path, and the bytes are
    /// forwarded verbatim — the far end does not decode them and neither does
    /// the transport. So what this pins is that `Data` survives as the same
    /// bytes, byte for byte, including the eight-byte PNG signature the host
    /// hands to `NSImage`.
    @Test("An icon response survives a round trip byte for byte")
    func applicationIconsResponseRoundTrip() throws {
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let icons: [String: Data] = [
            "/Applications/MobileSafari.app": pngSignature + Data(repeating: 0xAB, count: 512),
            "/Applications/Preferences.app": pngSignature,
        ]
        let decoded = try roundTrip(icons)
        #expect(decoded == icons)
        #expect(decoded["/Applications/MobileSafari.app"]?.starts(with: pngSignature) == true)
        #expect(decoded["/Applications/MobileSafari.app"]?.count == 520)
    }

    /// A bundle the far end has no icon for is *absent* from the response, not
    /// present with empty bytes. The host branches on the key being there, so
    /// an empty `Data` would reach `NSImage(data:)`, fail, and produce a blank
    /// row instead of the generic icon.
    @Test("An empty icon dictionary is a valid response")
    func emptyIconResponseRoundTrip() throws {
        #expect(try roundTrip([String: Data]()).isEmpty)
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

    /// The pid is the whole payload here, and it is also the whole identity: on
    /// the device side it is what the suspension controller counts references
    /// against, so a request that lost it would release nothing while reporting
    /// that it had.
    @Test("StopKeepingProcessAwakeRequest carries its pid across the wire")
    func stopKeepingProcessAwakeRequestRoundTrip() throws {
        let encoded = try JSONEncoder().encode(
            RuntimeEngine.StopKeepingProcessAwakeRequest(processIdentifier: 31337)
        )
        let decoded = try JSONDecoder().decode(
            RuntimeEngine.StopKeepingProcessAwakeRequest.self,
            from: encoded,
        )
        #expect(decoded.processIdentifier == 31337)
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

    /// The refusal is read by a user, so it has to name the engine *and* carry
    /// the transport's own reason. "Could not work out an address" on its own is
    /// unactionable; the reason is what says whether to retry or to change
    /// something.
    @Test("The refusal names the engine and quotes the transport's reason")
    func rendezvousRefusalIsReadable() throws {
        let message = try #require(
            RuntimePayloadRendezvous.Unavailable
                .peerCannotReachThisProcess(
                    engineName: "Someone's iPhone",
                    reason: "that connection runs over fe80::1, and an injected payload dials IPv4",
                )
                .errorDescription
        )
        #expect(message.contains("Someone's iPhone"))
        #expect(message.contains("fe80::1"))
        #expect(message.lowercased().contains("address"))
    }

    /// Each way of having no address has to produce its own sentence, or the
    /// error is back to being the single unactionable line it replaced.
    @Test("Every reason reaches the message intact")
    func everyReasonReachesTheMessage() throws {
        let reasons = [
            "that connection reports no network path yet",
            "that connection runs over fe80::1, and an injected payload dials IPv4",
            "this engine has no connection",
        ]
        for reason in reasons {
            let message = try #require(
                RuntimePayloadRendezvous.Unavailable
                    .peerCannotReachThisProcess(engineName: "iPhone", reason: reason)
                    .errorDescription
            )
            #expect(message.contains(reason))
        }
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
