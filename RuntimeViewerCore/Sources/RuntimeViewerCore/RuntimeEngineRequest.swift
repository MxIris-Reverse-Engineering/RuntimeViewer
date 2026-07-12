import Foundation
import RuntimeViewerCommunication

/// A typed RuntimeEngine command. Each conforming type carries its own wire
/// name plus the local `perform(on:)` implementation, so a single declaration
/// drives all three call sites: the client-side dispatch, the server-side
/// handler registration, and `RuntimeEngineProxyServer`'s handler registration.
///
/// Adding a new command therefore reduces to (1) declaring a new conformer and
/// (2) appending it to `RuntimeEngine.registerSharedHandlers(on:engine:)`. Both
/// server entry points pick the new handler up automatically — no more parallel
/// edits between `RuntimeEngine` and `RuntimeEngineProxyServer`.
public protocol RuntimeEngineRequest: Codable & Sendable {
    associatedtype Response: Codable & Sendable

    static var commandName: String { get }

    func perform(on engine: RuntimeEngine) async throws -> Response
}

/// Fire-and-forget marker so that `Void`-returning commands can ride the same
/// `RuntimeEngineRequest` machinery as response-bearing ones. Encodes as `{}`.
public struct RuntimeEngineEmpty: Codable, Sendable {
    public init() {}
}

// MARK: - Progress-reporting requests

/// A `RuntimeEngineRequest` whose execution emits incremental progress
/// alongside its final response.
///
/// Conformers get the full progress pipeline for free — client-side routing,
/// server-side push-back, and transparent relaying across chained proxies
/// (a `RuntimeEngineProxyServer` wrapping an engine that is itself a client
/// of another process). Declaring a new progress-bearing command reduces to:
///  1. conforming the request type to this protocol, and
///  2. registering it via `registerProgress(_:on:engine:)` in
///     `RuntimeEngine.registerSharedHandlers(on:engine:)` (instead of
///     `register(_:on:engine:)`).
///
/// ## Wire form
/// Progress requests travel as `RuntimeEngineProgressEnvelope`
/// (`{progressToken, request}`) under the request's own `commandName` —
/// never as the bare request, so plain and progress-listening callers share
/// one server handler. While the request executes, the serving peer pushes
/// `RuntimeEngineProgressPush` (`{token, payload}`) frames on the shared
/// `CommandNames.progressEvent` channel; the requesting engine routes each
/// push back to the in-flight call by token, so concurrent requests never
/// cross-talk. A `nil` token means the caller doesn't observe progress and
/// the serving peer skips the pushes entirely.
public protocol RuntimeEngineProgressRequest: RuntimeEngineRequest {
    associatedtype Progress: Codable & Sendable

    /// Local implementation reporting incremental progress. Implementations
    /// must `await` `reportProgress` at each report site so events stay
    /// ordered end-to-end (the wire layer serializes on that await).
    func perform(on engine: RuntimeEngine, reportProgress: @escaping @Sendable (Progress) async -> Void) async throws -> Response
}

extension RuntimeEngineProgressRequest {
    /// Plain execution defaults to the progress-bearing variant with a no-op
    /// listener, so conformers implement a single method.
    public func perform(on engine: RuntimeEngine) async throws -> Response {
        try await perform(on: engine) { _ in }
    }
}

/// Wire envelope for `RuntimeEngineProgressRequest` round trips. See the
/// protocol's "Wire form" note.
struct RuntimeEngineProgressEnvelope<Request: Codable & Sendable>: Codable, Sendable {
    /// Routing key the serving peer must echo on every progress push for this
    /// round trip; `nil` disables progress reporting.
    let progressToken: String?
    let request: Request
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
    /// Register a single request type on `connection`, routing inbound
    /// commands of that type through `engine.dispatch(_:)`.
    ///
    /// Routing through `dispatch` (rather than calling `perform(on: engine)`
    /// directly) matters for `RuntimeEngineProxyServer`: the proxied engine may
    /// itself be a *client* of another process (e.g. the Mac Catalyst helper or
    /// an attached app reached over XPC / local socket). `dispatch` forwards the
    /// request upstream in that case, so commands like `loadImage` run in the
    /// process that actually owns the image. Calling `perform(on:)` here would
    /// run the local implementation in the proxy host process instead — which
    /// is how remote image loading regressed after the request unification
    /// (dlopen of e.g. `/System/iOSSupport/.../UIKitCore` in the wrong
    /// process). For server / local engines `dispatch` falls through to
    /// `perform(on:)`, so their behavior is unchanged.
    static func register<R: RuntimeEngineRequest>(
        _ requestType: R.Type,
        on connection: any RuntimeConnection,
        engine: RuntimeEngine
    ) {
        connection.setMessageHandler(name: R.commandName) { (request: R) -> R.Response in
            try await engine.dispatch(request)
        }
    }

    /// Register a progress-reporting request type on `connection`.
    ///
    /// The handler decodes the progress envelope, executes through
    /// `engine.dispatch(_:onProgress:)`, and relays every progress event back
    /// to the requesting peer tagged with the requester's token. Chained
    /// proxies compose with no per-command code: when the proxied engine is a
    /// client, its `dispatch` forwards the request upstream under a fresh
    /// token and the upstream's pushes flow into this closure, which re-pushes
    /// them downstream under the original requester's token.
    ///
    /// The progress push is best-effort (`try?`) — a dropped push must not
    /// fail the request itself, matching the pre-existing behavior of the
    /// hand-rolled `objectsLoadingProgress` channel this replaces.
    static func registerProgress<R: RuntimeEngineProgressRequest>(
        _ requestType: R.Type,
        on connection: any RuntimeConnection,
        engine: RuntimeEngine
    ) {
        connection.setMessageHandler(name: R.commandName) { (envelope: RuntimeEngineProgressEnvelope<R>) -> R.Response in
            guard let token = envelope.progressToken else {
                return try await engine.dispatch(envelope.request, onProgress: nil)
            }
            return try await engine.dispatch(envelope.request) { progress in
                guard let payload = try? JSONEncoder().encode(progress) else { return }
                try? await connection.sendMessage(
                    name: RuntimeEngine.CommandNames.progressEvent.commandName,
                    request: RuntimeEngineProgressPush(token: token, payload: payload)
                )
            }
        }
    }

    /// All request types that both `setupMessageHandlerForServer` and
    /// `RuntimeEngineProxyServer.setupRequestHandlers` need to expose.
    /// Adding a command requires only appending one line here — see the
    /// matching Request struct in `RuntimeEngine+Requests.swift` /
    /// `RuntimeEngine+GenericSpecialization.swift`.
    static func registerSharedHandlers(on connection: any RuntimeConnection, engine: RuntimeEngine) {
        register(IsImageLoadedRequest.self, on: connection, engine: engine)
        register(IsImageIndexedRequest.self, on: connection, engine: engine)
        register(MainExecutablePathRequest.self, on: connection, engine: engine)
        register(LoadImageRequest.self, on: connection, engine: engine)
        register(LoadImageForBackgroundIndexingRequest.self, on: connection, engine: engine)
        register(CanOpenImageRequest.self, on: connection, engine: engine)
        register(RpathsRequest.self, on: connection, engine: engine)
        register(DependenciesRequest.self, on: connection, engine: engine)
        register(ImageNameOfObjectRequest.self, on: connection, engine: engine)
        register(ExportModuleInfoRequest.self, on: connection, engine: engine)
        registerProgress(ObjectsInImageRequest.self, on: connection, engine: engine)
        register(InterfaceRequest.self, on: connection, engine: engine)
        register(HierarchyRequest.self, on: connection, engine: engine)
        register(RelationshipsRequest.self, on: connection, engine: engine)
        register(MemberAddressesRequest.self, on: connection, engine: engine)
        register(SpecializationRequestForObjectRequest.self, on: connection, engine: engine)
        register(SpecializationRequestForCandidateRequest.self, on: connection, engine: engine)
        register(RuntimePreflightRequest.self, on: connection, engine: engine)
        register(SpecializeRequest.self, on: connection, engine: engine)
    }
}
