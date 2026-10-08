import Testing
import Foundation
import Combine
import RuntimeViewerCommunication
@testable import RuntimeViewerCore
@testable import RuntimeViewerInjection

/// `RuntimeInjection.install()` is the one thing every process serving an
/// engine has to call, and forgetting it produces no compile error — only a
/// peer that looks to a host like a build too old to have these commands.
/// These tests pin what the call is supposed to achieve, so at least the
/// mechanism itself cannot regress silently.
@Suite("RuntimeInjection installation")
struct RuntimeInjectionInstallationTests {
    @Test("install() puts all five injection commands on a new connection")
    func installAddsEveryInjectionCommand() {
        RuntimeInjection.install()
        // Twice on purpose: an app and an XPC service it embeds each call it,
        // and the extension table is keyed by name, so the second must be a
        // no-op rather than a second installation.
        RuntimeInjection.install()

        let connection = RecordingConnection()
        RuntimeEngine.registerSharedHandlers(on: connection, engine: RuntimeEngine(source: .local))

        let installedNames = connection.installedNames
        for commandName: RuntimeEngine.CommandName in [
            .injectionCapability,
            .processList,
            .applicationIcons,
            .injectIntoProcess,
            .stopKeepingProcessAwake,
        ] {
            #expect(installedNames.contains(commandName.commandName))
        }
        // No name installed twice — which is what proves the second `install()`
        // did not add a second copy of the extension.
        #expect(Set(installedNames).count == installedNames.count)
    }

    @Test("install() with no service does not clear one already recorded")
    func installWithoutServiceKeepsTheRecordedOne() {
        let stub = StubInjectionService()

        RuntimeInjection.install(service: stub)
        RuntimeInjection.install()

        // The order of two calls in one process must not matter: a host that
        // also happens to have a service would otherwise lose it to whichever
        // entry point ran last.
        #expect(RuntimeInjection.service as? StubInjectionService === stub)
    }
}

// MARK: - Test doubles

private final class StubInjectionService: RuntimeInjectionService {
    func injectionAvailability() async -> RuntimeInjectionAvailability { .available }

    func processList() async throws -> [RuntimeProcess] { [] }

    func inject(
        intoProcessWithIdentifier processIdentifier: pid_t,
        rendezvous: RuntimePayloadRendezvous?,
    ) async -> RuntimeProcessInjectionResult {
        .failed(code: 0, reason: "stub")
    }
}

/// A connection that records the wire names handlers were installed under and
/// does nothing else. Every send is unreachable here: these tests assemble a
/// command table, they never exercise one.
private final class RecordingConnection: RuntimeConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedNames: [String] = []

    var installedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedNames
    }

    private func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        recordedNames.append(name)
    }

    private struct NotSendHere: Error {}

    let statePublisher = Empty<RuntimeConnectionState, Never>(completeImmediately: false)

    var state: RuntimeConnectionState { .connected }

    func stop() {}

    func sendMessage(name: String) async throws {
        throw NotSendHere()
    }

    func sendMessage<Request: Codable>(name: String, request: Request) async throws {
        throw NotSendHere()
    }

    func sendMessage<Response: Codable>(name: String) async throws -> Response {
        throw NotSendHere()
    }

    func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        throw NotSendHere()
    }

    func sendMessage<Response: Codable>(name: String, request: some Codable) async throws -> Response {
        throw NotSendHere()
    }

    func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        record(name)
    }

    func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {
        record(name)
    }

    func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {
        record(name)
    }

    func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type, handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        record(Request.identifier)
    }

    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        record(name)
    }
}
