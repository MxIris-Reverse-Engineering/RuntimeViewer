#if os(macOS)

import Foundation
import FoundationToolbox
public import Combine
import SwiftyXPC
public import HelperCommunication

// MARK: - Shared connection surface

/// The `RuntimeConnection` surface both ends of an XPC-service connection
/// share. Subclasses provide the two transport primitives — send one frame,
/// install one named handler — and everything typed is derived from those.
public class RuntimeXPCServiceConnection: RuntimeConnection, @unchecked Sendable {
    /// The transport's own message. A client sends it when it connects and
    /// again after the service was relaunched; the listener adopts the sender
    /// as its peer, reports `.connected` and answers it with nothing. It
    /// belongs to this layer, not to the engine: what it establishes is
    /// "this connection has a live service behind it", nothing about images.
    /// A dedicated instance's `hello` also carries its launch payload, which
    /// the listener hands its launch handler before answering.
    static let helloMessageName = "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeXPCServiceConnection.hello"

    let stateSubject = CurrentValueSubject<RuntimeConnectionState, Never>(.connecting)

    public var statePublisher: some Publisher<RuntimeConnectionState, Never> {
        stateSubject
    }

    public var state: RuntimeConnectionState {
        stateSubject.value
    }

    init() {}

    public func stop() {
        fatalError("Subclasses must override stop()")
    }

    // MARK: Transport primitives

    func sendFrame(name: String, payload: Data) async throws -> Data {
        fatalError("Subclasses must override sendFrame(name:payload:)")
    }

    func installHandler(name: String, body: @escaping @Sendable (Data) async throws -> Data) {
        fatalError("Subclasses must override installHandler(name:body:)")
    }

    // MARK: Untyped (name-based) RPC

    public func sendMessage(name: String) async throws {
        _ = try await sendFrame(name: name, payload: Data())
    }

    public func sendMessage<Request: Codable>(name: String, request: Request) async throws {
        _ = try await sendFrame(name: name, payload: try RuntimeXPCServiceMessaging.encode(request))
    }

    public func sendMessage<Response: Codable>(name: String) async throws -> Response {
        let payload = try await sendFrame(name: name, payload: Data())
        return try RuntimeXPCServiceMessaging.decode(Response.self, from: payload)
    }

    public func sendMessage<Response: Codable>(name: String, request: some Codable) async throws -> Response {
        let payload = try await sendFrame(name: name, payload: try RuntimeXPCServiceMessaging.encode(request))
        return try RuntimeXPCServiceMessaging.decode(Response.self, from: payload)
    }

    // MARK: Typed RPC

    public func sendMessage<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        try await sendMessage(name: Request.identifier, request: request)
    }

    public func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type = Request.self, handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        setMessageHandler(name: Request.identifier) { (request: Request) -> Request.Response in
            try await handler(request)
        }
    }

    // MARK: Handlers

    public func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        installHandler(name: name) { _ in
            try await handler()
            return Data()
        }
    }

    public func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {
        installHandler(name: name) { payload in
            try await handler(try RuntimeXPCServiceMessaging.decode(Request.self, from: payload))
            return Data()
        }
    }

    public func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {
        installHandler(name: name) { _ in
            try RuntimeXPCServiceMessaging.encode(try await handler())
        }
    }

    public func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        installHandler(name: name) { payload in
            try RuntimeXPCServiceMessaging.encode(try await handler(try RuntimeXPCServiceMessaging.decode(Request.self, from: payload)))
        }
    }
}

#endif
