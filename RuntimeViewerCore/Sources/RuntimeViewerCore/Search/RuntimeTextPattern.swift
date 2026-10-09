public import Foundation

/// A Find query compiled the way the engine's searches compile theirs — the same match styles,
/// the same ASCII case folding, the same identifier boundaries, the same regular expressions —
/// for the app to find a hit again in text it has on screen.
///
/// A thin public face over `RuntimeInterfaceTextMatcher.Pattern`, so the app does not keep a
/// second copy of the matching rules that could drift from the engine's.
public struct RuntimeTextPattern: Sendable {
    private let pattern: RuntimeInterfaceTextMatcher.Pattern

    /// How long `ranges(in:)` may spend inside the regular expression engine before it gives up.
    private let timeLimit: TimeInterval

    /// Throws for an empty query and for a regular expression that does not compile.
    ///
    /// - Parameter timeLimit: the time one call of `ranges(in:)` may spend matching a regular
    ///   expression; a pattern that backtracks catastrophically finds nothing once it is spent.
    public init(text: String, matchMode: RuntimeInterfaceSearchMatchMode, isCaseSensitive: Bool, timeLimit: TimeInterval = 1) throws {
        self.pattern = try RuntimeInterfaceTextMatcher.Pattern(text: text, matchMode: matchMode, isCaseSensitive: isCaseSensitive)
        self.timeLimit = timeLimit
    }

    /// Every match in `text`, in order, as UTF-16 ranges; none when a regular expression runs
    /// out of time.
    public func ranges(in text: String) -> [NSRange] {
        var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget(timeLimit: timeLimit)
        guard let hits = try? RuntimeInterfaceTextMatcher.hits(in: text, pattern: pattern, budget: &budget) else { return [] }
        let utf8 = text.utf8
        return hits.map { hit in
            let startIndex = utf8.index(utf8.startIndex, offsetBy: hit.utf8Offset)
            let endIndex = utf8.index(startIndex, offsetBy: hit.utf8Length)
            return NSRange(startIndex ..< endIndex, in: text)
        }
    }
}
