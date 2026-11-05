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
