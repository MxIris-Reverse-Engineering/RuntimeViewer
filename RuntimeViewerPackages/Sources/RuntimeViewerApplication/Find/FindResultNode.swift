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
/// A class (an `NSObject`) because `NSOutlineView` identifies items by
/// pointer; `differenceIdentifier` is a string that stays stable across the
/// incremental batches a search delivers, so DifferenceKit keeps rows in
/// place while more arrive. The appearance is built on construction — every
/// field is known from the content — which is what lets the outline render
/// it without a ViewModel per row.
public final class FindResultNode: NSObject, @unchecked Sendable {
    public enum Content: Hashable {
        /// A type grouping the hits or members found in it.
        case object(RuntimeObject, matchCount: Int)
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

    /// The type a click navigates to, and where in it, or `nil` for an
    /// unresolved relationship node.
    public var navigationTarget: (object: RuntimeObject, highlight: ContentHighlightRequest?)? {
        switch content {
        case .object(let object, _):
            return (object, nil)
        case .textMatch(let match):
            return (match.object, nil)
        case .member(let match):
            return (match.object, nil)
        case .relationship(_, let object):
            return object.map { ($0, nil) }
        }
    }

    /// The text the bottom filter bar matches against.
    public var filterableText: String {
        switch content {
        case .object(let object, _): object.displayName
        case .textMatch(let match): match.lineText
        case .member(let match): match.member.declarationText
        case .relationship(let name, _): name
        }
    }

    public init(content: Content, children: [FindResultNode] = [], identifier: String) {
        self.content = content
        self.children = children
        self.identifier = identifier
        self.appearance = Self.makeAppearance(for: content)
        super.init()
    }

    // MARK: - Construction

    public static func object(_ object: RuntimeObject, matchCount: Int, children: [FindResultNode]) -> FindResultNode {
        FindResultNode(content: .object(object, matchCount: matchCount), children: children, identifier: "object|\(object.kind)|\(object.name)|\(object.imagePath)")
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
        case .object(let object, _):
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

    private static func nameRange(of match: RuntimeMemberMatch) -> NSRange? {
        let declarationText = match.member.declarationText
        guard let found = declarationText.range(of: match.member.name) else { return nil }
        let location = declarationText.utf16.distance(from: declarationText.startIndex, to: found.lowerBound)
        let length = declarationText.utf16.distance(from: found.lowerBound, to: found.upperBound)
        return NSRange(location: location + match.matchRangeInName.location, length: match.matchRangeInName.length)
            .clamped(toLengthOf: NSRange(location: location, length: length))
    }
    #endif
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension FindResultNode: OutlineNodeType {}

extension FindResultNode: Differentiable {
    public var differenceIdentifier: String { identifier }

    public func isContentEqual(to source: FindResultNode) -> Bool {
        content == source.content && children.count == source.children.count
    }
}

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
#endif
