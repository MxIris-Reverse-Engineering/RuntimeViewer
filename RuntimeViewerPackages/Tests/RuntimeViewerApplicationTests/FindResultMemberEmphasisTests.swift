import AppKit
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// A member row shows the member's declaration with the part the query
/// matched set apart — also when the match lies in a later piece of a
/// multi-part selector, which the declaration spells with parameters in
/// between.
@Suite("Find member rows")
@MainActor
struct FindResultMemberEmphasisTests {
    private static let object = RuntimeObject(name: "SampleController", displayName: "SampleController", kind: .objc(.type(.class)), imagePath: "/fixture", children: [])

    private static func emphasizedText(ofMember name: String, declaredAs declarationText: String, matchRangeInName: RuntimeTextRange) -> String {
        let member = RuntimeMemberDeclaration(name: name, kind: .objcMethod, isStatic: false, declarationText: declarationText, lineNumber: 1)
        let match = RuntimeMemberMatch(object: object, member: member, matchRangeInName: matchRangeInName)
        let title = FindResultNode.member(match, index: 0).appearance.title
        var emphasizedText = ""
        title.enumerateAttribute(.font, in: NSRange(location: 0, length: title.length)) { font, range, _ in
            if (font as? NSFont) == FindResultCellStyle.emphasisFont {
                emphasizedText += title.attributedSubstring(from: range).string
            }
        }
        return emphasizedText
    }

    @Test("a match in a one-piece name is set apart where the declaration spells the name")
    func matchInWholeName() {
        let emphasizedText = Self.emphasizedText(
            ofMember: "initWithFrame:",
            declaredAs: "- (instancetype)initWithFrame:(NSRect)frameRect;",
            matchRangeInName: RuntimeTextRange(location: 4, length: 4)
        )
        #expect(emphasizedText == "With")
    }

    @Test("a match in a later piece of a selector is set apart in that piece")
    func matchInLaterSelectorPiece() {
        // `did` at offset 10 of the name, the start of its second piece.
        let emphasizedText = Self.emphasizedText(
            ofMember: "tableView:didSelectRowAtIndexPath:",
            declaredAs: "- (void)tableView:(NSTableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;",
            matchRangeInName: RuntimeTextRange(location: 10, length: 3)
        )
        #expect(emphasizedText == "did")
    }

    @Test("a name that also occurs inside a type name is set apart where it stands on its own")
    func nameThatAlsoOccursInsideATypeName() {
        let emphasizedText = Self.emphasizedText(
            ofMember: "URL",
            declaredAs: "@property (readonly, copy) NSURL *URL;",
            matchRangeInName: RuntimeTextRange(location: 0, length: 3)
        )
        #expect(emphasizedText == "URL")
        let declarationText = "@property (readonly, copy) NSURL *URL;"
        #expect(Self.emphasizedRanges(ofMember: "URL", declaredAs: declarationText, matchRangeInName: RuntimeTextRange(location: 0, length: 3)) == [NSRange(location: (declarationText as NSString).range(of: "*URL").location + 1, length: 3)])
    }

    private static func emphasizedRanges(ofMember name: String, declaredAs declarationText: String, matchRangeInName: RuntimeTextRange) -> [NSRange] {
        let member = RuntimeMemberDeclaration(name: name, kind: .objcProperty, isStatic: false, declarationText: declarationText, lineNumber: 1)
        let match = RuntimeMemberMatch(object: object, member: member, matchRangeInName: matchRangeInName)
        let title = FindResultNode.member(match, index: 0).appearance.title
        var emphasizedRanges: [NSRange] = []
        title.enumerateAttribute(.font, in: NSRange(location: 0, length: title.length)) { font, range, _ in
            if (font as? NSFont) == FindResultCellStyle.emphasisFont {
                emphasizedRanges.append(range)
            }
        }
        return emphasizedRanges
    }
}
