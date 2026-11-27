import Foundation

extension RuntimeObject {
    /// Maximum length, in UTF-8 bytes, of a single path component on the
    /// filesystems RuntimeViewer exports to (APFS/HFS+ `NAME_MAX`). Writing a
    /// longer component throws `NSFileWriteInvalidFileNameError` (Cocoa 642).
    /// C++ template type names (e.g. a fully-spelled `std::unordered_map<…>`)
    /// routinely blow past this, so every export file name is clamped below.
    private static let maxFileNameByteLength = 255

    /// The objects an export writes for this one: itself, and for a C++
    /// class or namespace every class and namespace declared in it, depth
    /// first, each after the one it is declared in. A C++ interface names
    /// what is declared in it without printing it, so each of them is written
    /// on its own; an Objective-C or Swift object is written alone, as it
    /// always was (proposal `cplusplus-export`).
    ///
    /// A class template node is no declaration and is not written: its
    /// specializations are, in the order they took before there were template
    /// nodes, so an export writes what it always wrote (proposal
    /// `cplusplus-class-template-groups`). Call it on the objects a list
    /// gives through `[RuntimeObject].exportedObjects`, which keeps that order
    /// at the top level too.
    public var exportedObjects: [RuntimeObject] {
        guard kind.isCPlusPlus else { return [self] }
        guard kind != .cPlusPlus(.classTemplate) else { return children.flatMap(\.exportedObjects) }
        return [self] + children.exportedObjects
    }

    public var exportFileName: String {
        let invalidCharacters = CharacterSet(charactersIn: "/:<>\"\\|?*")
        let sanitized = fileNameSource
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
        case .cPlusPlus:
            base = sanitized
            suffix = ".hpp"
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

    /// What a file name is made from. A C++ object is named by its qualified
    /// name, since its display name is only the last component and the same
    /// one is declared in many namespaces; the global namespace, whose name
    /// is `::`, is `GlobalNamespace`.
    private var fileNameSource: String {
        guard kind.isCPlusPlus else { return displayName }
        if name == CPlusPlusObjectTreeBuilder.globalNamespaceName {
            return "GlobalNamespace"
        }
        return name
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
