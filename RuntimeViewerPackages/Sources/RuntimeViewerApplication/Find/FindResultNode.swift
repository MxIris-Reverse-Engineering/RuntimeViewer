#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

import Foundation
import RuntimeViewerCore
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
/// a hit, a member, or a node of a relationship tree.
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
        }
    }

    /// What type-select matches the row by: the start of the text it shows.
    public var typeSelectString: String {
        String(filterableText.drop { $0.isWhitespace })
    }

    public convenience init(content: Content, children: [FindResultNode] = [], identifier: String) {
        self.init(content: content, children: children, identifier: identifier, appearance: Self.makeAppearance(for: content))
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

    public static func relationship(_ node: RuntimeRelationshipNode, path: String) -> FindResultNode {
        let identifier = path + "/" + (node.object.map { "\($0.kind)|\($0.name)" } ?? node.name)
        return FindResultNode(
            content: .relationship(name: node.name, object: node.object),
            children: node.children.enumerated().map { index, child in relationship(child, path: identifier + "#\(index)") },
            identifier: identifier
        )
    }

    // MARK: - Appearance

    private static func makeAppearance(for content: Content) -> FindResultCellAppearance {
        var appearance = FindResultCellAppearance()
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        switch content {
        case .object(let object):
            appearance.icon = RuntimeObjectIcon.icon(for: object.kind, size: FindResultCellStyle.iconSize)
            appearance.title = titleWithSubtitle(object.displayName, subtitle: object.imageName)
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
                appearance.icon = RuntimeObjectIcon.icon(for: object.kind, size: FindResultCellStyle.iconSize)
                appearance.title = titleWithSubtitle(object.displayName, subtitle: object.imageName)
            } else {
                appearance.icon = FindResultCellStyle.unresolvedIcon
                appearance.iconAlpha = FindResultCellStyle.unresolvedIconAlpha
                appearance.title = plainTitle(name, color: FindResultCellStyle.unresolvedTitleColor)
                appearance.isSecondary = true
            }
        }
        #endif
        return appearance
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private static func plainTitle(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: FindResultCellStyle.titleFont, .foregroundColor: color])
    }

    /// `Name  image` — the type's name, then the image it is in, the way a
    /// file row shows its group.
    private static func titleWithSubtitle(_ title: String, subtitle: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: title, attributes: [.font: FindResultCellStyle.titleFont, .foregroundColor: FindResultCellStyle.titleColor])
        if !subtitle.isEmpty {
            result.append(NSAttributedString(string: FindResultCellStyle.subtitleSeparator + subtitle, attributes: [.font: FindResultCellStyle.subtitleFont, .foregroundColor: FindResultCellStyle.subtitleColor]))
        }
        return result
    }

    /// The line with the hit set apart in the emphasis font and colour.
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
