import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences

/// Which icon each kind of Find row shows, as a value; RuntimeViewerAppUI draws it. The sizes are the
/// icon frame of the list the row is in (`FindResultCellStyle.Metrics.iconSize`), which only a badge
/// is drawn at: the symbols keep their own size inside it.
enum FindResultIcon {
    /// How opaque the line and unresolved symbols are drawn, and a level that is loading or failed:
    /// Xcode draws those glyphs at 45 %.
    static let dimmedAlpha: CGFloat = 0.45

    /// A cross-reference root's icon: its member's badge, or its type's.
    static func crossReferenceIcon(for root: FindCrossReferenceRoot, size: CGFloat) -> IconDescriptor {
        switch root {
        case .member(let member, _):
            memberBadge(for: member, size: size)
        case .function(let function):
            functionBadge(for: function, size: size)
        case .type(let object):
            .runtimeObject(object.kind, size: size)
        }
    }

    /// A cross-reference row's icon: a recursive call's arrows, the badge of
    /// what the row stands for, an image's kind, or the loading and failure
    /// glyphs.
    static func crossReferenceIcon(for row: FindCrossReferenceRow, size: CGFloat) -> IconDescriptor {
        if row.isRecursive {
            return .findResultSymbol(.recursiveCall)
        }
        switch row.item {
        case .function(let function):
            return functionBadge(for: function, size: size)
        case .target(.selector):
            return badge("M", color: .orange, size: size)
        case .target(.importedSymbol(let name)):
            return languageBadge(for: RuntimeFunctionLanguage(symbol: name), size: size)
        case .target(.type(_, let object?)):
            return .runtimeObject(object.kind, size: size)
        case .target(.type(_, nil)):
            return badge("T", color: .gray, size: size)
        case .target(.function(let function)):
            return functionBadge(for: function, size: size)
        case .target(.indirect), .target(.unrecognizedCode):
            return .findResultSymbol(.unresolved)
        case .image(let path):
            return .imageKind(RuntimeImageKind(ofImageAt: path))
        case .unnamedFunctions:
            return languageBadge(for: nil, size: size)
        case .loading:
            return .findResultSymbol(.loading)
        case .failure:
            return .findResultSymbol(.failure)
        }
    }

    /// `M` for a method, `P` for a property or variable — orange on the
    /// Objective-C side and blue on the Swift side, the colours the type badges
    /// use.
    private static func memberBadge(for member: RuntimeMemberReference, size: CGFloat) -> IconDescriptor {
        let color: RuntimeObjectIcon.Glyph.Color = member.kind.isObjC ? .orange : .blue
        switch member.kind {
        case .objcProperty, .swiftVariable, .swiftField, .objcIvar:
            return badge("P", color: color, size: size)
        case .swiftEnumCase:
            return badge("E", color: color, size: size)
        case .objcMethod, .swiftFunction, .swiftInitializer, .swiftSubscript:
            return badge("M", color: color, size: size)
        }
    }

    /// A member's badge; otherwise the badge of the language its name tells.
    private static func functionBadge(for function: RuntimeFunctionReference, size: CGFloat) -> IconDescriptor {
        if let member = function.member {
            return memberBadge(for: member, size: size)
        }
        return languageBadge(for: function.language, size: size)
    }

    /// A function's badge by its language, in the colours the member badges
    /// use: `f` in blue for Swift, `M` in orange for an Objective-C method, `f`
    /// in green for C and C++, and in grey for a function nothing names.
    private static func languageBadge(for language: RuntimeFunctionLanguage?, size: CGFloat) -> IconDescriptor {
        switch language {
        case .swift?: badge("f", color: .blue, size: size)
        case .objectiveC?: badge("M", color: .orange, size: size)
        case .cOrCPlusPlus?: badge("f", color: .green, size: size)
        case nil: badge("f", color: .gray, size: size)
        }
    }

    private static func badge(_ text: String, color: RuntimeObjectIcon.Glyph.Color, size: CGFloat) -> IconDescriptor {
        .glyph(RuntimeObjectIcon.glyph(text: text, color: color, size: size))
    }
}
