import Foundation
import Semantic
import Testing
@testable import RuntimeViewerCore

/// Aligning structured members with printed text: names, selectors,
/// overloads claimed in order, keyword-only declarations, and members the
/// text does not carry.
@Suite("RuntimeMemberDeclarationLocator")
struct RuntimeMemberDeclarationLocatorTests {
    private func member(_ name: String, _ kind: RuntimeMemberKind, isStatic: Bool = false) -> RuntimeMemberDeclaration {
        RuntimeMemberDeclaration(name: name, kind: kind, isStatic: isStatic, declarationText: name, lineNumber: nil)
    }

    @Test("Objective-C properties, selectors and ivars find their lines")
    func objectiveC() {
        /// ```
        /// @interface Foo : NSObject {
        ///     NSInteger _count;
        /// }
        /// @property (nonatomic) NSInteger count;
        /// - (void)setValue:(id)value forKey:(NSString *)key;
        /// + (instancetype)shared;
        /// @end
        /// ```
        let interface: FrozenSemanticString = SemanticString {
            Keyword("@interface")
            Standard(" Foo : NSObject {\n    ")
            TypeName(kind: .other, "NSInteger")
            Standard(" ")
            Variable("_count")
            Standard(";\n}\n")
            Keyword("@property")
            Standard(" (nonatomic) ")
            TypeName(kind: .other, "NSInteger")
            Standard(" ")
            MemberDeclaration("count")
            Standard(";\n- (void)")
            // The renderer prints each selector piece without its colon.
            FunctionDeclaration("setValue")
            Standard(":(id)value ")
            FunctionDeclaration("forKey")
            Standard(":(NSString *)key;\n+ (instancetype)")
            FunctionDeclaration("shared")
            Standard(";\n")
            Keyword("@end")
        }.frozen()

        let located = RuntimeMemberDeclarationLocator.locate([
            member("count", .objcProperty),
            member("setValue:forKey:", .objcMethod),
            member("shared", .objcMethod, isStatic: true),
            member("_count", .objcIvar),
            member("missing", .objcProperty),
        ], in: interface)

        #expect(located.map(\.lineNumber) == [4, 5, 6, 2, nil])
        #expect(located[0].declarationText == "@property (nonatomic) NSInteger count;")
        #expect(located[1].declarationText == "- (void)setValue:(id)value forKey:(NSString *)key;")
        #expect(located[3].declarationText == "NSInteger _count;")
        #expect(located[4].declarationText == "missing")
    }

    @Test("Swift functions, overloads, subscripts and initializers")
    func swift() {
        /// ```
        /// class Foo {
        ///     var count: Int
        ///     init(count: Int)
        ///     func foo(bar: Int)
        ///     func foo(baz: String)
        ///     subscript(index: Int) -> Int
        /// }
        /// ```
        let interface: FrozenSemanticString = SemanticString {
            Keyword("class")
            Standard(" ")
            TypeName(kind: .class, "Foo")
            Standard(" {\n    ")
            Keyword("var")
            Standard(" ")
            Variable("count")
            Standard(": Int\n    ")
            Keyword("init")
            Standard("(")
            FunctionDeclaration("count")
            Standard(": Int)\n    ")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("foo")
            Standard("(")
            FunctionDeclaration("bar")
            Standard(": Int)\n    ")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("foo")
            Standard("(")
            FunctionDeclaration("baz")
            Standard(": String)\n    ")
            Keyword("subscript")
            Standard("(index: Int) -> Int\n}")
        }.frozen()

        let located = RuntimeMemberDeclarationLocator.locate([
            member("foo", .swiftFunction),
            member("foo", .swiftFunction),
            member("foo", .swiftFunction),
            member("count", .swiftVariable),
            member("subscript", .swiftSubscript),
            member("init", .swiftInitializer),
        ], in: interface)

        // The two overloads take the two `foo` lines in order; a third has
        // no line left.
        #expect(located.map(\.lineNumber) == [4, 5, nil, 2, 6, 3])
        #expect(located[4].declarationText == "subscript(index: Int) -> Int")
        #expect(located[5].declarationText == "init(count: Int)")
    }

    @Test("no member is located inside an excluded block, such as a nested type printed above the object's own members")
    func excludedBlocks() throws {
        /// ```
        /// struct Style {
        ///     enum CodingKeys {
        ///         case style
        ///         case locale
        ///     }
        ///     var style: Int
        ///     var locale: Locale
        /// }
        /// ```
        let interface: FrozenSemanticString = SemanticString {
            Keyword("struct")
            Standard(" ")
            TypeName(kind: .struct, "Style")
            Standard(" {\n    ")
            Keyword("enum")
            Standard(" ")
            TypeName(kind: .enum, "CodingKeys")
            Standard(" {\n        ")
            Keyword("case")
            Standard(" ")
            MemberDeclaration("style")
            Standard("\n        ")
            Keyword("case")
            Standard(" ")
            MemberDeclaration("locale")
            Standard("\n    }\n    ")
            Keyword("var")
            Standard(" ")
            Variable("style")
            Standard(": Int\n    ")
            Keyword("var")
            Standard(" ")
            Variable("locale")
            Standard(": Locale\n}")
        }.frozen()
        let text = interface.text
        let block = try #require(text.range(of: "    enum CodingKeys {\n        case style\n        case locale\n    }"))
        let excludedRange = text.utf8.distance(from: text.startIndex, to: block.lowerBound) ..< text.utf8.distance(from: text.startIndex, to: block.upperBound)

        let located = RuntimeMemberDeclarationLocator.locate([member("style", .swiftField), member("locale", .swiftField)], in: interface, excludingUTF8Ranges: [excludedRange])

        #expect(located.map(\.lineNumber) == [6, 7])
    }

    @Test("a span carrying line breaks advances the line count without claiming a name")
    func multilineSpans() {
        let interface: FrozenSemanticString = SemanticString {
            Comment("/* one\n   two */")
            Standard("\n")
            Variable("after")
        }.frozen()
        let located = RuntimeMemberDeclarationLocator.locate([member("after", .swiftVariable)], in: interface)
        #expect(located.map(\.lineNumber) == [3])
    }
}
