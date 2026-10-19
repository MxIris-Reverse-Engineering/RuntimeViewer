#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import RuntimeViewerUI
import RuntimeViewerArchitectures

/// What a Find result row is painted from: an icon, its opacity, the
/// attributed title, and whether the title may wrap onto a second line (a
/// hit's line does, a type name does not). The fonts, colours and icons come
/// from `FindResultCellStyle`.
public struct FindResultCellAppearance: Equatable {
    public var icon: NSUIImage?
    public var iconAlpha: CGFloat = 1
    public var title: NSAttributedString = .init()
    public var allowsWrapping = false
    public var isSecondary = false

    public init() {}
}

/// One row of the Find navigator's outline: a type with its hits underneath,
/// a hit, a member, a node of a relationship tree, or a row of a
/// cross-reference tree.
///
/// A class (an `NSObject`) because `NSOutlineView` takes objects as items.
/// Two nodes with the same `identifier` are equal, whichever instances they
/// are: AppKit keeps a row expanded and finds its row only for an item equal
/// to the one it knows, and every update of the results brings new nodes.
/// What a row shows is compared by `isContentEqual(to:)`. The identifier
/// stays stable across the incremental batches a search delivers, so
/// DifferenceKit keeps rows in place while more arrive. The appearance is
/// built on construction — every field is known from the content — which is
/// what lets the outline render it without a ViewModel per row.
public final class FindResultNode: NSObject, @unchecked Sendable {
    public enum Content: Hashable {
        /// A type grouping the hits or members found in it, which are its children.
        case object(RuntimeObject)
        case textMatch(RuntimeInterfaceSearchMatch)
        case member(RuntimeMemberMatch)
        /// A node of a relationship tree. `object` is `nil` for a type no
        /// indexed image defines; the row then shows `name` and goes nowhere.
        case relationship(name: String, object: RuntimeObject?)
        /// What a cross-reference search starts from; what it found loads
        /// below it.
        case crossReferenceRoot(FindCrossReferenceRoot, direction: FindCrossReferenceDirection)
        /// A row a cross-reference search found below another.
        case crossReference(FindCrossReferenceRow)
    }

    public let content: Content

    public let children: [FindResultNode]

    public let identifier: String

    public let appearance: FindResultCellAppearance

    /// The type a click navigates to, or `nil` for an unresolved
    /// relationship node. Where in the type a hit sits is `FindViewModel`'s to
    /// work out, from the query the results answer.
    public var navigationTarget: RuntimeObject? {
        switch content {
        case .object(let object):
            return object
        case .textMatch(let match):
            return match.object
        case .member(let match):
            return match.object
        case .relationship(_, let object):
            return object
        case .crossReferenceRoot(let root, _):
            return root.navigationTarget
        case .crossReference(let row):
            return row.navigationTarget
        }
    }

    /// Whether the row goes somewhere, so its context menu offers Open in New Tab: an
    /// unresolved relationship node does not.
    public var canOpenInNewTab: Bool {
        navigationTarget != nil
    }

    /// The text the bottom filter bar matches against.
    public var filterableText: String {
        switch content {
        case .object(let object): object.displayName
        case .textMatch(let match): match.lineText
        case .member(let match): match.member.declarationText
        case .relationship(let name, _): name
        case .crossReferenceRoot(let root, _): root.title
        case .crossReference(let row): row.title
        }
    }

    /// What type-select matches the row by: the start of the text it shows.
    public var typeSelectString: String {
        String(filterableText.drop { $0.isWhitespace })
    }

    public convenience init(content: Content, children: [FindResultNode] = [], identifier: String) {
        self.init(content: content, children: children, identifier: identifier, appearance: Self.makeNavigatorAppearance(for: content))
    }

    /// `node` with other children — what the filter bar keeps of a row — sharing its appearance,
    /// which depends on the content alone, instead of building it again.
    public convenience init(copying node: FindResultNode, children: [FindResultNode]) {
        self.init(content: node.content, children: children, identifier: node.identifier, appearance: node.appearance)
    }

    private init(content: Content, children: [FindResultNode], identifier: String, appearance: FindResultCellAppearance) {
        self.content = content
        self.children = children
        self.identifier = identifier
        self.appearance = appearance
        super.init()
    }

    // MARK: - Identity

    /// The same row, whichever instance: the identifiers match. See the type's
    /// documentation for why the outline needs this.
    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FindResultNode else { return false }
        return identifier == other.identifier
    }

    public override var hash: Int {
        identifier.hashValue
    }

    // MARK: - Construction

    public static func object(_ object: RuntimeObject, children: [FindResultNode]) -> FindResultNode {
        FindResultNode(content: .object(object), children: children, identifier: "object|\(object.kind)|\(object.name)|\(object.imagePath)")
    }

    public static func textMatch(_ match: RuntimeInterfaceSearchMatch, index: Int) -> FindResultNode {
        FindResultNode(content: .textMatch(match), identifier: "text|\(match.object.kind)|\(match.object.name)|\(match.object.imagePath)|\(match.lineNumber)|\(match.matchRangeInLine.location)|\(index)")
    }

    public static func member(_ match: RuntimeMemberMatch, index: Int) -> FindResultNode {
        FindResultNode(content: .member(match), identifier: "member|\(match.object.kind)|\(match.object.name)|\(match.object.imagePath)|\(match.member.kind.rawValue)|\(match.member.name)|\(index)")
    }

    /// A root of a cross-reference tree, with the rows loaded below it.
    static func crossReferenceRoot(_ root: FindCrossReferenceRoot, direction: FindCrossReferenceDirection, identifier: String, children: [FindResultNode]) -> FindResultNode {
        FindResultNode(content: .crossReferenceRoot(root, direction: direction), children: children, identifier: identifier)
    }

    /// A row of a cross-reference tree. Its identifier is its path from the
    /// root, so a row keeps its place, its expansion and its selection when
    /// the rows above it load more.
    static func crossReference(_ row: FindCrossReferenceRow, identifier: String, children: [FindResultNode]) -> FindResultNode {
        FindResultNode(content: .crossReference(row), children: children, identifier: identifier)
    }

    public static func relationship(_ node: RuntimeRelationshipNode, path: String) -> FindResultNode {
        let identifier = path + "/" + (node.object.map { "\($0.kind)|\($0.name)" } ?? node.name)
        return FindResultNode(
            content: .relationship(name: node.name, object: node.object),
            children: node.children.enumerated().map { index, child in relationship(child, path: identifier + "#\(index)") },
            identifier: identifier
        )
    }

    // MARK: - Appearance

    /// The row as the Find navigator draws it. Nothing draws one off AppKit.
    private static func makeNavigatorAppearance(for content: Content) -> FindResultCellAppearance {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return makeAppearance(for: content, metrics: .navigator)
        #else
        return FindResultCellAppearance()
        #endif
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// A row showing `content`, at `metrics`' sizes: the Find navigator's, or
    /// the Inspector's References tab's, which lists cross-reference rows a
    /// size down.
    static func makeAppearance(for content: Content, metrics: FindResultCellStyle.Metrics) -> FindResultCellAppearance {
        var appearance = FindResultCellAppearance()
        switch content {
        case .object(let object):
            appearance.icon = RuntimeObjectIcon.icon(for: object.kind, size: metrics.iconSize)
            appearance.title = titleWithSubtitle(object.displayName, subtitle: FindScope.imageName(of: object.imagePath), metrics: metrics)
        case .textMatch(let match):
            appearance.icon = FindResultCellStyle.matchIcon
            appearance.iconAlpha = FindResultCellStyle.matchIconAlpha
            appearance.title = emphasized(match.lineText, range: match.matchRangeInLine.nsRange)
            appearance.allowsWrapping = true
        case .member(let match):
            appearance.icon = FindResultCellStyle.matchIcon
            appearance.iconAlpha = FindResultCellStyle.matchIconAlpha
            appearance.title = emphasized(match.member.declarationText, range: Self.nameRange(of: match))
            appearance.allowsWrapping = true
        case .relationship(let name, let object):
            if let object {
                appearance.icon = RuntimeObjectIcon.icon(for: object.kind, size: metrics.iconSize)
                appearance.title = titleWithSubtitle(object.displayName, subtitle: FindScope.imageName(of: object.imagePath), metrics: metrics)
            } else {
                appearance.icon = FindResultCellStyle.unresolvedIcon
                appearance.iconAlpha = FindResultCellStyle.unresolvedIconAlpha
                appearance.title = plainTitle(name, color: FindResultCellStyle.unresolvedTitleColor, metrics: metrics)
                appearance.isSecondary = true
            }
        case .crossReferenceRoot(let root, _):
            appearance.icon = FindResultCellStyle.crossReferenceIcon(for: root, metrics: metrics)
            appearance.title = titleWithSubtitle(root.title, subtitle: FindScope.imageName(of: root.imagePath), metrics: metrics)
        case .crossReference(let row):
            appearance.icon = FindResultCellStyle.crossReferenceIcon(for: row, metrics: metrics)
            switch row.item {
            case .loading, .failure:
                appearance.iconAlpha = FindResultCellStyle.unresolvedIconAlpha
                appearance.title = plainTitle(row.title, color: FindResultCellStyle.unresolvedTitleColor, metrics: metrics)
                appearance.isSecondary = true
            case .function, .target, .image:
                appearance.title = titleWithSubtitle(row.title, subtitle: row.subtitle, metrics: metrics)
            }
        }
        return appearance
    }

    /// A one-line title in one colour.
    private static func plainTitle(_ text: String, color: NSColor, metrics: FindResultCellStyle.Metrics) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: metrics.titleFont,
            .foregroundColor: color,
            .paragraphStyle: FindResultCellStyle.titleParagraphStyle,
        ])
    }

    /// `Name  image` — the type's name, then the image it is in, the way a
    /// file row shows its group — on one line.
    private static func titleWithSubtitle(_ title: String, subtitle: String, metrics: FindResultCellStyle.Metrics) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title, attributes: [
            .font: metrics.titleFont,
            .foregroundColor: FindResultCellStyle.titleColor,
            .paragraphStyle: FindResultCellStyle.titleParagraphStyle,
        ])
        if !subtitle.isEmpty {
            result.append(NSAttributedString(string: FindResultCellStyle.subtitleSeparator + subtitle, attributes: [
                .font: metrics.subtitleFont,
                .foregroundColor: FindResultCellStyle.subtitleColor,
                .paragraphStyle: FindResultCellStyle.titleParagraphStyle,
            ]))
        }
        return result
    }

    /// The line with the hit set apart in the emphasis font and colour. It
    /// keeps the default paragraph style, which wraps by word: a hit's line
    /// may take a second line (`FindResultCellAppearance.allowsWrapping`).
    private static func emphasized(_ text: String, range: NSRange?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: FindResultCellStyle.hitLineFont, .foregroundColor: FindResultCellStyle.hitLineColor])
        if let range, range.location >= 0, NSMaxRange(range) <= result.length {
            result.addAttributes([.font: FindResultCellStyle.emphasisFont, .foregroundColor: FindResultCellStyle.emphasisColor], range: range)
        }
        return result
    }
    #endif

    // MARK: - Member Names

    /// Where the query matched the member's name, inside its declaration. A
    /// name the declaration spells whole is found where it stands on its own —
    /// `URL` in `NSURL *URL` is the last one, not the one inside `NSURL`; a
    /// multi-part selector is spelled piece by piece with its parameters in
    /// between, so the piece the match starts in is found instead, keyword and
    /// colon. The row sets this range apart, and the content pane flashes it.
    static func nameRange(of match: RuntimeMemberMatch) -> NSRange? {
        let declarationText = match.member.declarationText as NSString
        let name = match.member.name as NSString
        let matchRange = match.matchRangeInName.nsRange
        if let wholeNameRange = identifierRange(of: name as String, in: declarationText) {
            return NSRange(location: wholeNameRange.location + matchRange.location, length: matchRange.length)
                .clamped(toLengthOf: wholeNameRange)
        }
        guard let pieceRange = selectorPieceRange(in: name, containing: matchRange.location),
              let pieceRangeInDeclaration = identifierRange(of: name.substring(with: pieceRange), in: declarationText)
        else { return nil }
        return NSRange(location: pieceRangeInDeclaration.location + matchRange.location - pieceRange.location, length: matchRange.length)
            .clamped(toLengthOf: pieceRangeInDeclaration)
    }

    /// The piece of a selector, up to and including its colon, that the
    /// UTF-16 `offset` falls in.
    private static func selectorPieceRange(in name: NSString, containing offset: Int) -> NSRange? {
        var pieceStart = 0
        while pieceStart < name.length {
            let colonRange = name.range(of: ":", range: NSRange(location: pieceStart, length: name.length - pieceStart))
            let pieceEnd = colonRange.location == NSNotFound ? name.length : NSMaxRange(colonRange)
            if offset < pieceEnd {
                return NSRange(location: pieceStart, length: pieceEnd - pieceStart)
            }
            pieceStart = pieceEnd
        }
        return nil
    }

    /// The first place `identifier` stands on its own in `declarationText`: not preceded by an
    /// identifier character, and — unless it ends in a selector's colon — not followed by one.
    /// So a name is never found inside a longer one, at either end.
    private static func identifierRange(of identifier: String, in declarationText: NSString) -> NSRange? {
        let identifierText = identifier as NSString
        let checksTrailingBoundary = identifierText.length > 0 && isIdentifierCharacter(identifierText.character(at: identifierText.length - 1))
        var searchStart = 0
        while searchStart < declarationText.length {
            let found = declarationText.range(of: identifier, range: NSRange(location: searchStart, length: declarationText.length - searchStart))
            guard found.location != NSNotFound else { return nil }
            let startsOnItsOwn = found.location == 0 || !isIdentifierCharacter(declarationText.character(at: found.location - 1))
            let endsOnItsOwn = !checksTrailingBoundary || NSMaxRange(found) == declarationText.length || !isIdentifierCharacter(declarationText.character(at: NSMaxRange(found)))
            if startsOnItsOwn, endsOnItsOwn {
                return found
            }
            searchStart = found.location + 1
        }
        return nil
    }

    private static func isIdentifierCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return true }
        return scalar == "_" || scalar == "$" || CharacterSet.alphanumerics.contains(scalar)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension FindResultNode: OutlineNodeType {}

extension FindResultNode: Differentiable {
    public var differenceIdentifier: String { identifier }

    /// Whether the row and everything beneath it shows the same as `source`. The outline's
    /// adapter skips a row this calls unchanged, so it has to look at the whole subtree: the
    /// filter bar can swap which hits a type shows without changing how many.
    public func isContentEqual(to source: FindResultNode) -> Bool {
        if self === source {
            return true
        }
        // `content` compares a type by identity alone; the row also shows its display name,
        // which another run can spell differently.
        guard content == source.content,
              appearance.title.isEqual(to: source.appearance.title),
              children.count == source.children.count
        else { return false }
        return zip(children, source.children).allSatisfy { child, sourceChild in
            child.identifier == sourceChild.identifier && child.isContentEqual(to: sourceChild)
        }
    }
}

#endif

extension NSRange {
    /// `self` cut down to lie inside `bounds`; an empty range at `bounds.location`
    /// when they do not overlap.
    fileprivate func clamped(toLengthOf bounds: NSRange) -> NSRange {
        let lower = Swift.max(location, bounds.location)
        let upper = Swift.min(NSMaxRange(self), NSMaxRange(bounds))
        guard upper > lower else { return NSRange(location: bounds.location, length: 0) }
        return NSRange(location: lower, length: upper - lower)
    }
}
