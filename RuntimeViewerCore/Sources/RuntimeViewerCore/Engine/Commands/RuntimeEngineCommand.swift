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

    /// The one image whose data answers this request, when exactly one image
    /// does — the image a request about one image names, whatever the field
    /// it names it in is called.
    ///
    /// An engine that borrows shared cache images hands a request whose
    /// subject is one of them to the engine that owns it (see
    /// `RuntimeSharedCacheOwners`), so a command about one image declares
    /// it. `nil`, the default, keeps the request with the engine it was sent
    /// to: a question about the serving process itself, or one about every
    /// image it has indexed. Computed, never stored, so declaring it changes
    /// nothing on the wire.
    var subjectImagePath: String? { get }

    /// Whether the request is a load made for the user, which holds back the
    /// background indexing of the engine that serves it — the engine a
    /// borrowed request is handed to as well as the one it was sent to.
    static var isForegroundLoad: Bool { get }

    /// Whether the subject image has both sections built once the request
    /// returns. The engine a borrowed request is handed to announces the
    /// image on its `imageDidIndexPublisher` then, as it would for a request
    /// made on it directly, so its corpus and cross-reference work picks the
    /// image up.
    static var indexesSubjectImage: Bool { get }

    func perform(on engine: RuntimeEngine) async throws -> Response
}

extension RuntimeEngineCommand {
    public var subjectImagePath: String? {
        nil
    }

    public static var isForegroundLoad: Bool {
        false
    }

    public static var indexesSubjectImage: Bool {
        false
    }
}
