import Foundation

/// The search the batch export image picker runs over its image tree: the text, how to read it,
/// and which string of each image it is matched against.
///
/// Only images are matched. A folder is never a match by itself; it shows up because an image
/// under it matched, which is why searching a folder's name finds nothing in `.name` mode and
/// everything beneath it in `.fullPath` mode.
public struct BatchExportingImageQuery: Equatable, Sendable {
    public enum MatchMode: Int, CaseIterable, CustomStringConvertible, Sendable {
        /// The text occurs somewhere in the matched string.
        case contains
        /// The text is a regular expression found somewhere in the matched string, the way grep
        /// finds it; `^` and `$` anchor it.
        case regularExpression

        public var description: String {
            switch self {
            case .contains:
                "Contains"
            case .regularExpression:
                "Regular Expression"
            }
        }
    }

    public enum MatchTarget: Int, CaseIterable, CustomStringConvertible, Sendable {
        /// The image's file name, such as `UIKitCore`.
        case name
        /// The image's full path, such as
        /// `/System/Library/PrivateFrameworks/UIKitCore.framework/Versions/A/UIKitCore`.
        case fullPath

        public var description: String {
            switch self {
            case .name:
                "Name"
            case .fullPath:
                "Full Path"
            }
        }
    }

    public var text: String

    public var matchMode: MatchMode

    public var matchTarget: MatchTarget

    public var isCaseSensitive: Bool

    public init(
        text: String = "",
        matchMode: MatchMode = .contains,
        matchTarget: MatchTarget = .name,
        isCaseSensitive: Bool = false
    ) {
        self.text = text
        self.matchMode = matchMode
        self.matchTarget = matchTarget
        self.isCaseSensitive = isCaseSensitive
    }

    /// Blank text filters nothing, whatever the other options say.
    public var isEmpty: Bool {
        text.allSatisfy(\.isWhitespace)
    }
}

/// The two strings of one image a query can be matched against, copied out of the tree so that
/// matching can run off the main actor.
struct BatchExportingImageMatchCandidate: Sendable {
    let name: String

    let path: String
}

/// A query compiled once per filter pass.
struct BatchExportingImageMatcher {
    /// The query's text is not a regular expression. `reason` is the parser's own message, such as
    /// `expected ')'`.
    struct InvalidRegularExpression: Swift.Error {
        let reason: String
    }

    private let matchTarget: BatchExportingImageQuery.MatchTarget

    private let isMatching: (String) -> Bool

    init(query: BatchExportingImageQuery) throws(InvalidRegularExpression) {
        matchTarget = query.matchTarget
        switch query.matchMode {
        case .contains:
            // Leading and trailing spaces are typing noise here, not something to look for.
            let searchedText = query.text.trimmingCharacters(in: .whitespaces)
            let compareOptions: String.CompareOptions = query.isCaseSensitive ? [] : [.caseInsensitive]
            isMatching = { $0.range(of: searchedText, options: compareOptions) != nil }
        case .regularExpression:
            let regularExpression: Regex<AnyRegexOutput>
            do {
                regularExpression = try Regex(query.text)
            } catch {
                throw InvalidRegularExpression(reason: String(describing: error))
            }
            let effectiveRegularExpression = query.isCaseSensitive ? regularExpression : regularExpression.ignoresCase()
            isMatching = { $0.contains(effectiveRegularExpression) }
        }
    }

    func matches(_ candidate: BatchExportingImageMatchCandidate) -> Bool {
        switch matchTarget {
        case .name:
            isMatching(candidate.name)
        case .fullPath:
            isMatching(candidate.path)
        }
    }
}
