import Foundation
import Compression

extension Data {
    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLengthPrefixed(_ string: String) {
        let bytes = Data(string.utf8)
        appendLittleEndian(UInt32(bytes.count))
        append(bytes)
    }
}
