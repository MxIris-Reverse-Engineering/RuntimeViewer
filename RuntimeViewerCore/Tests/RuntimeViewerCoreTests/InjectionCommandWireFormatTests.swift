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

    /// `executablePath` is deliberately optional — "could not read it" is a real
    /// state for a live process — so both forms have to survive the wire.
    @Test("RuntimeProcess survives a round trip with and without an executable path")
    func processRoundTrip() throws {
        let withPath = RuntimeProcess(
            processIdentifier: 4321,
            name: "backboardd",
            executablePath: "/usr/libexec/backboardd",
            userIdentifier: 501,
            injectability: .injectable,
        )
        let withoutPath = RuntimeProcess(
            processIdentifier: 1,
            name: "launchd",
            executablePath: nil,
            userIdentifier: 0,
            injectability: .requiresRootOnTarget,
        )
        #expect(try roundTrip(withPath) == withPath)
        #expect(try roundTrip(withoutPath) == withoutPath)
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
    @Test("InjectIntoProcessRequest carries its pid across the wire")
    func injectRequestRoundTrip() throws {
        let encoded = try JSONEncoder().encode(RuntimeEngine.InjectIntoProcessRequest(processIdentifier: 31337))
        let decoded = try JSONDecoder().decode(RuntimeEngine.InjectIntoProcessRequest.self, from: encoded)
        #expect(decoded.processIdentifier == 31337)
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
