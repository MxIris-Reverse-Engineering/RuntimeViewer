import Foundation

/// A typed RuntimeEngine command. Each conforming type carries its own wire
/// name plus the local `perform(on:)` implementation, so a single declaration
/// drives all three call sites: the client-side dispatch, the server-side
/// handler registration, and `RuntimeEngineProxyServer`'s handler registration.
///
/// Adding a new command therefore reduces to (1) declaring a new conformer and
/// (2) registering it — one line in `RuntimeEngine.registerBuiltInHandlers(into:)`
/// for a command of Core's own, or a `RuntimeEngineCommandRegistrar.register(_:)`
/// call inside `RuntimeEngine.addCommandExtension(named:install:)` for one
/// belonging to another module. Both server entry points pick the new handler up
/// automatically — no more parallel edits between `RuntimeEngine` and
/// `RuntimeEngineProxyServer`, and nothing in Core to edit for a command that
/// is not Core's.
public protocol RuntimeEngineCommand: Codable & Sendable {
    associatedtype Response: Codable & Sendable

    static var commandName: String { get }

    func perform(on engine: RuntimeEngine) async throws -> Response
}

/// Fire-and-forget marker so that `Void`-returning commands can ride the same
/// `RuntimeEngineCommand` machinery as response-bearing ones. Encodes as `{}`.
public struct RuntimeEngineEmpty: Codable, Sendable {
    public init() {}
}

// MARK: - Progress-reporting commands

/// A `RuntimeEngineCommand` whose execution emits incremental progress
/// alongside its final response.
///
/// Conformers get the full progress pipeline for free — client-side routing,
/// server-side push-back, and transparent relaying across chained proxies
/// (a `RuntimeEngineProxyServer` wrapping an engine that is itself a client
/// of another process). Declaring a new progress-bearing command reduces to:
///  1. conforming the request type to this protocol, and
///  2. registering it with `RuntimeEngineCommandRegistrar.registerProgress(_:)`
///     instead of `register(_:)`.
///
/// ## Wire form
/// Progress requests travel as `RuntimeEngineProgressEnvelope`
/// (`{progressToken, request}`) under the request's own `commandName` —
/// never as the bare request, so plain and progress-listening callers share
/// one server handler. While the request executes, the serving peer pushes
/// `RuntimeEngineProgressPush` (`{token, payload}`) frames on the shared
/// `CommandName.progressEvent` channel; the requesting engine routes each
/// push back to the in-flight call by token, so concurrent requests never
/// cross-talk. A `nil` token means the caller doesn't observe progress and
/// the serving peer skips the pushes entirely.
public protocol RuntimeEngineProgressCommand: RuntimeEngineCommand {
    associatedtype Progress: Codable & Sendable

    /// Local implementation reporting incremental progress. Implementations
    /// must `await` `reportProgress` at each report site so events stay
    /// ordered end-to-end (the wire layer serializes on that await).
    func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (Progress) async -> Void) async throws -> Response
}

extension RuntimeEngineProgressCommand {
    /// Plain execution defaults to the progress-bearing variant with a no-op
    /// listener, so conformers implement a single method.
    public func perform(on engine: RuntimeEngine) async throws -> Response {
        try await perform(on: engine) { _ in }
    }
}

/// Wire envelope for `RuntimeEngineProgressCommand` round trips. See the
/// protocol's "Wire form" note.
struct RuntimeEngineProgressEnvelope<Command: Codable & Sendable>: Codable, Sendable {
    /// Routing key the serving peer must echo on every progress push for this
    /// round trip; `nil` disables progress reporting.
    let progressToken: String?

    /// The command itself. **Named `request` on purpose**: this is a `Codable`
    /// stored property, so its name is a JSON key that peers built before the
    /// `Request` → `Command` rename still encode and decode. Renaming it would
    /// change the wire format, which the rename deliberately did not.
    let request: Command
}

/// A single progress event pushed back to the requester on the shared
/// `progressEvent` channel.
struct RuntimeEngineProgressPush: Codable, Sendable {
    let token: String
    /// JSON-encoded `Progress` value. Kept as raw `Data` so the push handler
    /// stays untyped; the requester's routing table decodes it with the
    /// concrete type captured at `dispatch(_:onProgress:)` time.
    let payload: Data
}

extension RuntimeEngine {
    /// Core's own commands, installed on every connection before any
    /// extension module's.
    ///
    /// Adding a command to Core is one line here plus the matching command
    /// struct in `RuntimeEngine+Commands.swift` /
    /// `RuntimeEngine+GenericSpecialization.swift`. A command belonging to
    /// another module does not come here at all — see
    /// ``addCommandExtension(named:install:)``.
    static func registerBuiltInHandlers(into registrar: RuntimeEngineCommandRegistrar) {
        registrar.register(IsImageLoadedCommand.self)
        registrar.register(IsImageIndexedCommand.self)
        registrar.register(MainExecutablePathCommand.self)
        registrar.register(LoadImageCommand.self)
        registrar.registerProgress(LoadImageWithProgressCommand.self)
        registrar.register(LoadImageForBackgroundIndexingCommand.self)
        registrar.register(ReloadDataCommand.self)
        registrar.register(CanOpenImageCommand.self)
        registrar.register(RpathsCommand.self)
        registrar.register(DependenciesCommand.self)
        registrar.register(ImageNameOfObjectCommand.self)
        registrar.register(ExportModuleInfoCommand.self)
        registrar.registerProgress(ObjectsInImageCommand.self)
        registrar.register(InterfaceCommand.self)
        registrar.register(HierarchyCommand.self)
        registrar.register(RelationshipsCommand.self)
        registrar.register(CounterpartCommand.self)
        registrar.register(MemberAddressesCommand.self)
        registrar.register(SpecializationRequestForObjectCommand.self)
        registrar.register(SpecializationRequestForCandidateCommand.self)
        registrar.register(RuntimePreflightCommand.self)
        registrar.register(SpecializeCommand.self)
    }
}
