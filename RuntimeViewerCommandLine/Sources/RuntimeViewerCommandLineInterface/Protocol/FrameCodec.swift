import Foundation

/// Length-prefixed framing: a 4-byte big-endian payload length followed by the
/// JSON payload.
public enum FrameCodec {
    /// Upper bound on a single payload. A full type list of a large image is a
    /// few megabytes; anything near this bound is a corrupt length field.
    public static let maximumPayloadLength = 256 * 1024 * 1024

    public static let headerLength = 4

    public enum FrameError: Error, Equatable {
        case payloadTooLarge(Int)
    }

    public static func encodeFrame(payload: Data) throws -> Data {
        guard payload.count <= maximumPayloadLength else {
            throw FrameError.payloadTooLarge(payload.count)
        }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: headerLength)
        frame.append(payload)
        return frame
    }

    /// Accumulates bytes as they arrive and yields whole payloads.
    public struct Decoder: Sendable {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ data: Data) {
            buffer.append(data)
        }

        /// The next complete payload, or `nil` while the buffer holds a partial frame.
        public mutating func nextPayload() throws -> Data? {
            guard buffer.count >= FrameCodec.headerLength else { return nil }
            let length = buffer.prefix(FrameCodec.headerLength).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let payloadLength = Int(length)
            guard payloadLength <= FrameCodec.maximumPayloadLength else {
                throw FrameError.payloadTooLarge(payloadLength)
            }
            let frameLength = FrameCodec.headerLength + payloadLength
            guard buffer.count >= frameLength else { return nil }
            let payload = buffer.subdata(in: FrameCodec.headerLength ..< frameLength)
            buffer.removeSubrange(0 ..< frameLength)
            return payload
        }

        public var pendingByteCount: Int { buffer.count }
    }
}

/// JSON configuration shared by both ends of the wire and by `--json` output.
public enum WireCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Encodes a message and wraps it in a frame.
    public static func encodeFrame<Message: Encodable>(_ message: Message) throws -> Data {
        try FrameCodec.encodeFrame(payload: try makeEncoder().encode(message))
    }

    public static func decode<Message: Decodable>(_ type: Message.Type, from payload: Data) throws -> Message {
        try makeDecoder().decode(type, from: payload)
    }
}
