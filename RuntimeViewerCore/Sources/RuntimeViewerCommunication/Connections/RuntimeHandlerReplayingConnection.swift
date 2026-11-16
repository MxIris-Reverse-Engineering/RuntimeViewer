import Foundation

/// A connection whose transport connection is replaced over its lifetime — a
/// server accepting the next client, a client reconnecting — and whose message
/// handlers therefore live in a `RuntimeMessageHandlerReplay` rather than on
/// the transport connection of the moment.
///
/// A conformer hands every new transport connection to
/// `messageHandlerReplay.apply(to:)` before the connection starts receiving.
protocol RuntimeHandlerReplayingConnection: RuntimeForwardingConnection {
    var messageHandlerReplay: RuntimeMessageHandlerReplay<Connection> { get }
}

// MARK: - Recorded Handlers

extension RuntimeHandlerReplayingConnection {
    func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        messageHandlerReplay.record(name: name, applyingTo: underlyingConnection) { connection in
            connection.setMessageHandler(name: name) { @Sendable (_: RuntimeMessageNull) in
                try await handler()
                return RuntimeMessageNull.null
            }
        }
    }

    func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {
        messageHandlerReplay.record(name: name, applyingTo: underlyingConnection) { connection in
            connection.setMessageHandler(name: name) { @Sendable (request: Request) in
                try await handler(request)
                return RuntimeMessageNull.null
            }
        }
    }

    func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {
        messageHandlerReplay.record(name: name, applyingTo: underlyingConnection) { connection in
            connection.setMessageHandler(name: name) { @Sendable (_: RuntimeMessageNull) in
                try await handler()
            }
        }
    }

    func setMessageHandler<Request: RuntimeRequest>(requestType: Request.Type, handler: @escaping @Sendable (Request) async throws -> Request.Response) {
        messageHandlerReplay.record(name: Request.identifier, applyingTo: underlyingConnection) { connection in
            connection.setMessageHandler(handler)
        }
    }

    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        messageHandlerReplay.record(name: name, applyingTo: underlyingConnection) { connection in
            connection.setMessageHandler(name: name, handler: handler)
        }
    }
}
