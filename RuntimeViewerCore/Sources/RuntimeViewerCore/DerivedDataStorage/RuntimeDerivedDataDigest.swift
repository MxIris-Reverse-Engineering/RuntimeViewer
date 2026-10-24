import Foundation
import CryptoKit

/// The SHA-256 digests derived data names and checks its files with.
enum RuntimeDerivedDataDigest {
    /// The digest of `data` in lowercase hexadecimal, all 64 digits.
    static func hexadecimalDigest(of data: some DataProtocol) -> String {
        hexadecimalString(of: SHA256.hash(data: data))
    }

    /// The first eight bytes of the digest of `data`: what a container
    /// stores to tell a damaged section or header from an intact one. Not a
    /// defence against anyone — the files live in the user's own caches —
    /// only against a torn write or a flipped bit.
    static func checksum(of data: some DataProtocol) -> UInt64 {
        var checksum: UInt64 = 0
        for byte in SHA256.hash(data: data).prefix(8) {
            checksum = checksum << 8 | UInt64(byte)
        }
        return checksum
    }

    static func hexadecimalString(of bytes: some Sequence<UInt8>) -> String {
        bytes.map { byte in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }
        .joined()
    }
}
