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

extension RuntimeEngine {
    /// Register a single request type on `connection`, routing inbound
    /// commands of that type to `perform(on: engine)`.
    static func register<R: RuntimeEngineRequest>(
        _ requestType: R.Type,
        on connection: RuntimeConnection,
        engine: RuntimeEngine
    ) {
        connection.setMessageHandler(name: R.commandName) { (request: R) -> R.Response in
            try await request.perform(on: engine)
        }
    }

    /// All request types that both `setupMessageHandlerForServer` and
    /// `RuntimeEngineProxyServer.setupRequestHandlers` need to expose.
    /// Adding a command requires only appending one line here — see the
    /// matching Request struct in `RuntimeEngine+Requests.swift` /
    /// `RuntimeEngine+GenericSpecialization.swift`.
    static func registerSharedHandlers(on connection: RuntimeConnection, engine: RuntimeEngine) {
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
        register(ObjectsInImageRequest.self, on: connection, engine: engine)
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
