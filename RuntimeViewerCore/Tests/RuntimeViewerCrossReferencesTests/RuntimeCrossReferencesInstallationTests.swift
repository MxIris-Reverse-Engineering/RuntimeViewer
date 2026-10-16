import Testing
import Foundation
import Combine
import RuntimeViewerCommunication
@testable import RuntimeViewerCore
@testable import RuntimeViewerCrossReferences

/// `RuntimeCrossReferences.install()` is the one call every process serving an
/// engine owes this module, and forgetting it is no compile error — only a
/// peer that looks to a host like a build too old to have these commands.
@Suite("RuntimeCrossReferences installation")
struct RuntimeCrossReferencesInstallationTests {
    @Test("install() puts both cross-reference commands on a new connection")
    func installAddsEveryCrossReferenceCommand() {
        RuntimeCrossReferences.install()
        // Twice on purpose: the app and the XPC services it embeds each call
        // it, and the second must be a no-op rather than a second copy.
        RuntimeCrossReferences.install()

        let connection = RecordingConnection()
        RuntimeEngine.registerSharedHandlers(on: connection, engine: RuntimeEngine(source: .local))

        let installedNames = connection.installedNames
        for commandName: RuntimeEngine.CommandName in [.crossReferenceCallees, .crossReferenceCallers] {
            #expect(installedNames.contains(commandName.commandName))
        }
        #expect(Set(installedNames).count == installedNames.count)
    }
}

/// A connection that records the wire names handlers were installed under and
/// does nothing else.
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
