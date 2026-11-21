import Foundation
import Testing
import Semantic
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// How the application layer shows C++ objects (proposal `cplusplus-objects`):
/// their group in the Filter Scope, their glyphs and the links in their
/// interfaces.
@Suite("C++ objects in the application layer")
@MainActor
struct CPlusPlusPresentationTests {
    @Test("the Filter Scope has a C++ group, between C and Objective-C, holding classes and namespaces")
    func filterScopeHasCPlusPlusGroup() {
        #expect(RuntimeObjectScope.KindGroup.allCases == [.c, .cPlusPlus, .objectiveC, .swift])
        #expect(RuntimeObjectScope.KindGroup.cPlusPlus.title == "C++")
        #expect(RuntimeObjectScope.KindGroup.cPlusPlus.kinds == [.cPlusPlus(.class), .cPlusPlus(.namespace)])
        #expect(RuntimeObjectScope.KindGroup.of(.cPlusPlus(.namespace)) == .cPlusPlus)
        #expect(RuntimeObjectScope.allRepresentableKinds.isSuperset(of: [.cPlusPlus(.class), .cPlusPlus(.namespace)]))
    }

    @Test("a scope remembered before C++ objects lets them through")
    func rememberedScopeLetsCPlusPlusThrough() throws {
        // What a release before C++ objects stored: the kinds it left out, none of them C++.
        let excludedKinds = String(decoding: try JSONEncoder().encode([RuntimeObjectKind.swift(.extension(.struct))]), as: UTF8.self)
        let remembered = try JSONDecoder().decode(RuntimeObjectScope.self, from: Data(#"{"excludedKinds":\#(excludedKinds)}"#.utf8))
        #expect(!remembered.includedKinds.contains(.swift(.extension(.struct))))
        #expect(remembered.includedKinds.contains(.cPlusPlus(.class)))
        #expect(remembered.includedKinds.contains(.cPlusPlus(.namespace)))
    }

    @Test("C++ classes and namespaces are a green C and N")
    func cPlusPlusIconsAreGreenCAndN() {
        let classGlyph = RuntimeObjectIcon.glyph(for: .cPlusPlus(.class))
        let namespaceGlyph = RuntimeObjectIcon.glyph(for: .cPlusPlus(.namespace))
        #expect(classGlyph.text == "C")
        #expect(classGlyph.color == .green)
        #expect(namespaceGlyph.text == "N")
        #expect(namespaceGlyph.color == .green)
    }

    @Test("a C++ interface links class tokens to classes and other type tokens to namespaces, by their full names")
    func cPlusPlusLinkTargetsAreClassesAndNamespaces() throws {
        let owner = Fixtures.runtimeObject(name: "ui::Widget", kind: .cPlusPlus(.class), imagePath: TestImages.libobjc)
        let semanticString = SemanticString {
            Keyword("class")
            Standard(" ")
            TypeDeclaration(kind: .class, "ui::Widget")
            Standard(" : ")
            TypeName(kind: .class, "ui::View")
            Standard(" {}\n")
            TypeName(kind: .other, "ui::detail")
        }
        .frozen()
        let links = ContentInterface.links(in: semanticString, of: owner)
        #expect(links.map(\.target.name) == ["ui::Widget", "ui::View", "ui::detail"])
        #expect(links.map(\.target.kind) == [.cPlusPlus(.class), .cPlusPlus(.class), .cPlusPlus(.namespace)])
        #expect(links.allSatisfy { $0.target.imagePath == owner.imagePath })
    }
}
