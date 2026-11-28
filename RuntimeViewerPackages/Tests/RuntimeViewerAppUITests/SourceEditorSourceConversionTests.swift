import Foundation
import Testing
import Semantic
import RuntimeViewerCore
@testable import RuntimeViewerAppUI

/// `SourceEditorSourceConversion`, what both content panes hand the editor with an interface's text.
@Suite("SourceEditorSourceConversion")
struct SourceEditorSourceConversionTests {
    @Test("semantic runs are counted in UTF-16, so a character outside the basic plane takes two")
    func semanticRunsCountUTF16OutsideTheBasicPlane() {
        let semanticString = SemanticString {
            Standard("// 😀\n")
            TypeName(kind: .class, "NSObject")
        }
        .frozen()

        let runs = SourceEditorSourceConversion.semanticRuns(of: semanticString)

        #expect(runs.ranges.map(\.rangeValue) == [NSRange(location: 0, length: 6), NSRange(location: 6, length: 8)])
        #expect(runs.nodeTypeNames == ["xcode.syntax.plain", "xcode.syntax.identifier.class"])
    }

    @Test("a run's node type is the theme key of its style")
    func semanticRunsUseTheThemeKeys() {
        let semanticString = SemanticString {
            Keyword("class")
            Standard(" ")
            TypeName(kind: .class, "Widget")
        }
        .frozen()

        let runs = SourceEditorSourceConversion.semanticRuns(of: semanticString)

        #expect(runs.nodeTypeNames == ["xcode.syntax.keyword", "xcode.syntax.plain", "xcode.syntax.identifier.class"])
    }

    @Test("an Objective-C object's Generated Interface is highlighted as Swift")
    func languageIdentifierIsSwiftForAGeneratedSwiftInterfaceOfAnObjCObject() {
        #expect(SourceEditorSourceConversion.languageIdentifier(for: .objc(.type(.class)), interfaceLanguage: .swift) == "swift")
        #expect(SourceEditorSourceConversion.languageIdentifier(for: .objc(.type(.class)), interfaceLanguage: nil) == "objc")
    }

    @Test("C++ objects are highlighted as C++, C ones as Objective-C")
    func languageIdentifierIsCppForCPlusPlusObjects() {
        #expect(SourceEditorSourceConversion.languageIdentifier(for: .cPlusPlus(.class), interfaceLanguage: nil) == "cpp")
        #expect(SourceEditorSourceConversion.languageIdentifier(for: .c(.struct), interfaceLanguage: nil) == "objc")
    }
}
