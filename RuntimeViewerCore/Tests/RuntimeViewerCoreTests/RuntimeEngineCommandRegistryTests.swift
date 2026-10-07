import Testing
import Foundation
import Combine
import RuntimeViewerCommunication
@testable import RuntimeViewerCore

/// The command table is what decides whether a peer has a handler for an
/// incoming command, and a missing or shadowed one shows up only between two
/// processes — one sends a command the other never registered. These tests pin
/// the assembly itself: that every built-in command lands under its own wire
/// name, that a second claim on a name is refused rather than silently
/// overwriting, and that a module's extension is installed after the built-ins.
///
/// Together they replace the `CommandNames.allCases` uniqueness check the
/// closed enum allowed. The replacement is stronger: `allCases` could only
/// prove the *declarations* were distinct, while this proves the handlers
/// actually installed are — across modules, which `allCases` could never see.
@Suite("RuntimeEngine command registry")
struct RuntimeEngineCommandRegistryTests {
    // MARK: - Built-in commands

    @Test("Every built-in command installs under its own wire name")
    func builtInCommandsInstallUnderDistinctNames() {
        let connection = RecordingConnection()
        let registrar = RuntimeEngineCommandRegistrar(connection: connection, engine: RuntimeEngine(source: .local))

        RuntimeEngine.registerBuiltInHandlers(into: registrar)

        let installedNames = connection.installedNames
        #expect(!installedNames.isEmpty)
        // A duplicate would show up as a handler count above the distinct-name
        // count: the registrar refuses the second claim, so the connection
        // never sees it.
        #expect(Set(installedNames).count == installedNames.count)
        #expect(registrar.installedCommandNames == Set(installedNames))
        #expect(installedNames.allSatisfy { $0.hasPrefix(RuntimeEngine.CommandName.namespacePrefix) })
    }

    @Test("A second declaration of an installed command name is dropped")
    func duplicateCommandNameIsDropped() {
        let connection = RecordingConnection()
        let registrar = RuntimeEngineCommandRegistrar(connection: connection, engine: RuntimeEngine(source: .local))
        RuntimeEngine.registerBuiltInHandlers(into: registrar)
        let namesBeforeTheCollision = connection.installedNames

        registrar.register(CommandNameCollidingCommand.self)

        // First come wins, and the built-ins come first — so Core keeps the
        // name and the handler count does not move.
        #expect(connection.installedNames == namesBeforeTheCollision)
        #expect(registrar.installedCommandNames.contains(RuntimeEngine.CommandName.isImageLoaded.commandName))
    }

    // MARK: - Command extensions

    /// Asserted through a process-level observation box rather than by counting
    /// invocations: a command extension cannot be withdrawn once added, so it
    /// also runs for every connection any other test in this process sets up.
    /// Both assertions below are therefore written to be insensitive to extra
    /// runs — they check *which* closure ran, never how many times.
    @Test("A command extension installs after the built-ins, once per name")
    func commandExtensionsInstallAfterTheBuiltIns() {
        RuntimeEngine.addCommandExtension(named: Self.probeExtensionName) { registrar in
            CommandExtensionProbe.shared.recordFirstClosure(
                sawBuiltInCommands: registrar.installedCommandNames.contains(RuntimeEngine.CommandName.isImageLoaded.commandName),
            )
            registrar.register(CommandExtensionProbeCommand.self)
        }
        // Same name, different closure: the table keeps the first, so this one
        // must never run.
        RuntimeEngine.addCommandExtension(named: Self.probeExtensionName) { _ in
            CommandExtensionProbe.shared.recordSecondClosure()
        }

        let connection = RecordingConnection()
        RuntimeEngine.registerSharedHandlers(on: connection, engine: RuntimeEngine(source: .local))

        #expect(CommandExtensionProbe.shared.firstClosureSawBuiltInCommands == true)
        #expect(CommandExtensionProbe.shared.secondClosureRan == false)
        #expect(connection.installedNames.contains(CommandExtensionProbeCommand.commandName))
    }

    private static let probeExtensionName = "RuntimeViewerCoreTests.commandRegistryProbe"
}

// MARK: - Test doubles

/// A request type that deliberately claims a built-in command's wire name.
private struct CommandNameCollidingCommand: RuntimeEngineCommand {
    static var commandName: String { RuntimeEngine.CommandName.isImageLoaded.commandName }

    func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
        RuntimeEngineEmpty()
    }
}

/// A request type standing in for one an extension module would declare.
private struct CommandExtensionProbeCommand: RuntimeEngineCommand {
    static var commandName: String {
        RuntimeEngine.CommandName("runtimeViewerCoreTestsCommandExtensionProbe").commandName
    }

    func perform(on engine: RuntimeEngine) async throws -> RuntimeEngineEmpty {
        RuntimeEngineEmpty()
    }
}

/// What the probe extension's closures observed, kept at process level because
/// the extension table is.
private final class CommandExtensionProbe: @unchecked Sendable {
    static let shared = CommandExtensionProbe()

    private let lock = NSLock()
    private var firstClosureObservation: Bool?
    private var hasSecondClosureRun = false

    var firstClosureSawBuiltInCommands: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return firstClosureObservation
    }

    var secondClosureRan: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasSecondClosureRun
    }

    func recordFirstClosure(sawBuiltInCommands: Bool) {
        lock.lock()
        defer { lock.unlock() }
        firstClosureObservation = sawBuiltInCommands
    }

    func recordSecondClosure() {
        lock.lock()
        defer { lock.unlock() }
        hasSecondClosureRun = true
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
