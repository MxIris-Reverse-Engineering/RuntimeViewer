public import Foundation
import Compression

/// Reads little-endian values out of bytes, throwing instead of reading past
/// `limit`.
struct RuntimeDerivedDataByteReader {
    let data: Data

    /// From the start of `data`.
    var offset = 0

    var limit: Int

    init(_ data: Data) {
        self.data = data
        limit = data.count
    }

    var isAtEnd: Bool {
        offset == limit
    }

    mutating func readUInt8() throws -> UInt8 {
        try readInteger()
    }

    mutating func readUInt16() throws -> UInt16 {
        try readInteger()
    }

    mutating func readUInt32() throws -> UInt32 {
        try readInteger()
    }

    mutating func readUInt64() throws -> UInt64 {
        try readInteger()
    }

    mutating func readInt64() throws -> Int64 {
        try readInteger()
    }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, count <= limit - offset else { throw RuntimeDerivedDataContainer.Error.truncated }
        let start = data.startIndex + offset
        offset += count
        return data[start ..< start + count]
    }

    /// A UInt32 byte count and that many bytes of valid UTF-8.
    mutating func readLengthPrefixedString() throws -> String {
        let byteCount = Int(try readUInt32())
        let bytes = try readBytes(count: byteCount)
        guard let string = String(data: bytes, encoding: .utf8), string.utf8.count == byteCount else {
            throw RuntimeDerivedDataContainer.Error.truncated
        }
        return string
    }

    private mutating func readInteger<Integer: FixedWidthInteger>() throws -> Integer {
        let byteCount = MemoryLayout<Integer>.size
        guard byteCount <= limit - offset else { throw RuntimeDerivedDataContainer.Error.truncated }
        let start = data.startIndex + offset
        offset += byteCount
        let value = data[start ..< start + byteCount].withUnsafeBytes { $0.loadUnaligned(as: Integer.self) }
        return Integer(littleEndian: value)
    }
}
