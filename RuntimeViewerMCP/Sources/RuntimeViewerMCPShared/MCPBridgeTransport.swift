import Foundation
import Network

// MARK: - Simple JSON-over-TCP transport for MCP Bridge communication
//
// Protocol: Each message is a 4-byte big-endian length prefix followed by UTF-8 JSON data.
// Request format:  { "identifier": "<command>", "payload": <json> }
// Response format: { "payload": <json> }

public struct MCPBridgeEnvelope: Codable, Sendable {
    public let identifier: String
    public let payload: Data

    public init(identifier: String, payload: Data) {
        self.identifier = identifier
        self.payload = payload
    }

    public init<T: Encodable>(identifier: String, value: T) throws {
        self.identifier = identifier
        self.payload = try JSONEncoder().encode(value)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

public struct MCPBridgeResponseEnvelope: Codable, Sendable {
    public let payload: Data

    public init(payload: Data) {
        self.payload = payload
    }

    public init<T: Encodable>(value: T) throws {
        self.payload = try JSONEncoder().encode(value)
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: payload)
    }
}

// MARK: - Frame encoding/decoding

public enum MCPBridgeFrame {
    public static func encode(_ data: Data) -> Data {
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        return frame
    }

    public static func send(_ data: Data, on connection: NWConnection) async throws {
        let frame = encode(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    public static func receive(from connection: NWConnection) async throws -> Data {
        // Read 4-byte length prefix
        let lengthData = try await receiveExact(from: connection, count: 4)
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length < 10_000_000 else {
            throw MCPBridgeTransportError.invalidFrameLength(length)
        }
        // Read payload
        return try await receiveExact(from: connection, count: Int(length))
    }

    private static func receiveExact(from connection: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, content.count == count {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(throwing: MCPBridgeTransportError.connectionClosed)
                } else {
                    continuation.resume(throwing: MCPBridgeTransportError.incompleteRead)
                }
            }
        }
    }
}

public enum MCPBridgeTransportError: Error, Sendable {
    case invalidFrameLength(UInt32)
    case connectionClosed
    case incompleteRead
    case encodingFailed
    case decodingFailed
    case serverNotRunning
    case connectionFailed
    case timeout
}
