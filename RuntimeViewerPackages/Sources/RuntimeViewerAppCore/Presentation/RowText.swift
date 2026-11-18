import Foundation

/// A row's text as runs of semantic roles: what each part of the text is, not how it is drawn. The list
/// or the Find navigator that shows the row decides the font and colour of each role
/// (`RowText.attributedString(in:)` in RuntimeViewerAppUI; proposal `app-core-without-ui-models`).
public struct RowText: Hashable, Sendable {
    /// What a run of the text is.
    public enum Role: Hashable, Sendable {
        /// The row's name.
        case primary
        /// A subtitle or an image's name; the part of a name a filter did not match in Open Quickly.
        case secondary
        /// The part of a name a filter did not match in the sidebar.
        case tertiary
        /// What a filter or a search matched.
        case emphasized
        /// A Find hit's line around the hit.
        case hitLine
        /// A Find row whose target could not be resolved, or that is loading or failed.
        case unresolved
    }

    /// A stretch of the text in one role.
    public struct Run: Hashable, Sendable {
        public var string: String
        public var role: Role

        public init(_ string: String, role: Role = .primary) {
            self.string = string
            self.role = role
        }
    }

    public var runs: [Run]

    /// The point size of the row's text; `nil` takes the size of the style that draws it (the Find
    /// navigator's are its own).
    public var fontSize: CGFloat?

    public init(_ string: String, role: Role = .primary, fontSize: CGFloat? = nil) {
        self.init(runs: [Run(string, role: role)], fontSize: fontSize)
    }

    public init(runs: [Run], fontSize: CGFloat? = nil) {
        self.runs = runs
        self.fontSize = fontSize
    }

    public static let empty = RowText(runs: [])

    /// The text without its roles, for type-select and accessibility.
    public var string: String {
        runs.map(\.string).joined()
    }

    /// A copy whose characters in `ranges` take `role`, the rest keeping theirs: how a filter's matches
    /// are marked. The ranges are UTF-16 offsets into `string`, as `NSAttributedString`'s are; a range
    /// that does not lie inside `string` is skipped.
    public func marking(_ ranges: [NSRange], as role: Role) -> RowText {
        let text = string as NSString
        // One role per UTF-16 unit, then runs again of consecutive units of one role.
        var roles: [Role] = []
        roles.reserveCapacity(text.length)
        for run in runs {
            roles.append(contentsOf: repeatElement(run.role, count: (run.string as NSString).length))
        }
        for range in ranges where range.location >= 0 && NSMaxRange(range) <= text.length {
            for index in range.location..<NSMaxRange(range) {
                roles[index] = role
            }
        }
        var markedRuns: [Run] = []
        var runStart = 0
        while runStart < roles.count {
            var runEnd = runStart + 1
            while runEnd < roles.count, roles[runEnd] == roles[runStart] {
                runEnd += 1
            }
            markedRuns.append(Run(text.substring(with: NSRange(location: runStart, length: runEnd - runStart)), role: roles[runStart]))
            runStart = runEnd
        }
        return RowText(runs: markedRuns, fontSize: fontSize)
    }
}
