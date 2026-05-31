import Foundation

extension RuntimeObject {
    /// Maximum length, in UTF-8 bytes, of a single path component on the
    /// filesystems RuntimeViewer exports to (APFS/HFS+ `NAME_MAX`). Writing a
    /// longer component throws `NSFileWriteInvalidFileNameError` (Cocoa 642).
    /// C++ template type names (e.g. a fully-spelled `std::unordered_map<…>`)
    /// routinely blow past this, so every export file name is clamped below.
    private static let maxFileNameByteLength = 255

    public var exportFileName: String {
        let invalidCharacters = CharacterSet(charactersIn: "/:<>\"\\|?*")
        let sanitized = displayName
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")

        let base: String
        let suffix: String
        switch kind {
        case .swift(.type(_)):
            base = sanitized
            suffix = ".swiftinterface"
        case .swift(.extension(_)):
            base = sanitized
            suffix = "+Extension.swiftinterface"
        case .swift(.conformance(_)):
            base = sanitized
            suffix = "+Conformance.swiftinterface"
        case .objc(.type(.class)), .c:
            base = sanitized
            suffix = ".h"
        case .objc(.type(.protocol)):
            base = sanitized
            suffix = "-Protocol.h"
        case .objc(.category(_)):
            if let categoryName = sanitized.contentInParentheses {
                base = sanitized.replacingOccurrences(of: "(\(categoryName))", with: "")
                suffix = "+\(categoryName).h"
            } else {
                base = sanitized
                suffix = ".h"
            }
        }

        return Self.clampFileName(base: base, suffix: suffix)
    }

    /// Joins `base + suffix`, clamping the result to `maxFileNameByteLength`.
    /// When the natural name fits, it is returned verbatim. When it doesn't,
    /// `base` is truncated and a short, deterministic hash of the *full* base is
    /// appended so two distinct long names that share a truncated prefix don't
    /// collide on disk (and the same object always maps to the same file name
    /// across runs). The `suffix` (extension / category tag) is never dropped.
    private static func clampFileName(base: String, suffix: String) -> String {
        let fullName = base + suffix
        if fullName.utf8.count <= maxFileNameByteLength {
            return fullName
        }

        let disambiguator = String(format: "~%08x", stableHash(of: base))
        let budget = maxFileNameByteLength - suffix.utf8.count - disambiguator.utf8.count
        let truncatedBase = base.truncatedToUTF8ByteLength(max(0, budget))
        return truncatedBase + disambiguator + suffix
    }

    /// FNV-1a 64-bit folded to 32 bits. Deterministic across processes (unlike
    /// `Hashable.hashValue`, which is per-run seeded), so the disambiguating
    /// suffix is stable for a given type name.
    private static func stableHash(of string: String) -> UInt32 {
        var hash: UInt64 = 14695981039346656037
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return UInt32(truncatingIfNeeded: hash) ^ UInt32(truncatingIfNeeded: hash >> 32)
    }
}

private extension String {
    /// Truncates to at most `maxBytes` UTF-8 bytes without splitting a
    /// `Character`, so the result is always valid UTF-8 even when the cut would
    /// otherwise land in the middle of a multi-byte scalar.
    func truncatedToUTF8ByteLength(_ maxBytes: Int) -> String {
        if utf8.count <= maxBytes { return self }
        var result = ""
        var byteCount = 0
        for character in self {
            let characterByteCount = String(character).utf8.count
            if byteCount + characterByteCount > maxBytes { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return result
    }
}
