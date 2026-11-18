import Foundation

/// The class prefix an image's types carry — `NS` for AppKit, `UI` for
/// UIKitCore, `MTL` for Metal — counted from the image's own type names
/// rather than looked up in a table: Apple's prefixes run to hundreds, private
/// frameworks have their own, and the rule holds for a third-party app too.
public enum NamingTypePrefix {
    /// The prefix most of `typeNames` start with, or `nil` when no prefix is
    /// common enough. A candidate is two or three capitals followed by
    /// another capital (`NSWindow`, `MTLDevice`); a three-letter one is taken
    /// over the two-letter one it extends when it accounts for nearly all of
    /// it, so that Metal's names give `MTL` and AppKit's `NSURL…` names do not
    /// turn `NS` into `NSU`.
    public static func detect(in typeNames: [String]) -> String? {
        var twoLetterCounts: [String: Int] = [:]
        var threeLetterCounts: [String: Int] = [:]
        for typeName in typeNames {
            let characters = Array(withoutLeadingUnderscores(typeName))
            if characters.count > 2, characters[0 ... 2].allSatisfy(\.isUppercase) {
                twoLetterCounts[String(characters[0 ..< 2]), default: 0] += 1
            }
            if characters.count > 3, characters[0 ... 3].allSatisfy(\.isUppercase) {
                threeLetterCounts[String(characters[0 ..< 3]), default: 0] += 1
            }
        }
        // The most common two-letter candidate; on a tie, the first in order.
        guard let (twoLetterPrefix, twoLetterCount) = twoLetterCounts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) else { return nil }
        let minimumCount = max(3, typeNames.count / 5)
        guard twoLetterCount >= minimumCount else { return nil }
        let longestExtension = threeLetterCounts
            .filter { $0.key.hasPrefix(twoLetterPrefix) }
            .max(by: { ($0.value, $1.key) < ($1.value, $0.key) })
        if let longestExtension, longestExtension.value * 10 >= twoLetterCount * 8 {
            return longestExtension.key
        }
        return twoLetterPrefix
    }

    /// `typeName` without `prefix`, when it starts with it and a capital
    /// follows; otherwise unchanged. Leading underscores are dropped first.
    public static func removing(_ prefix: String, from typeName: String) -> String {
        let name = withoutLeadingUnderscores(typeName)
        guard name.hasPrefix(prefix) else { return String(name) }
        let rest = name.dropFirst(prefix.count)
        guard let firstCharacter = rest.first, firstCharacter.isUppercase else { return String(name) }
        return String(rest)
    }

    private static func withoutLeadingUnderscores(_ name: String) -> Substring {
        name.drop { $0 == "_" }
    }
}
