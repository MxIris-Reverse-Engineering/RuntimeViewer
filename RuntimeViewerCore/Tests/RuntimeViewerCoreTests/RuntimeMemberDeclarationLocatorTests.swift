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

    /// The declarations `located` show as, read back out of `interface` the
    /// way a corpus entry reads a found member's line: the locator records
    /// lines, not their text.
    private func displayedDeclarationTexts(of located: [RuntimeMemberDeclaration], in interface: FrozenSemanticString) -> [String] {
        let entry = RuntimeInterfaceCorpusEntry(
            object: RuntimeObject(name: "Foo", displayName: "Foo", kind: .objc(.type(.class)), imagePath: "/Fixture", children: []),
            interface: interface,
            members: located
        )
        return located.indices.map { entry.displayedMember(at: $0).declarationText }
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
        // No line is copied into the members.
        #expect(located.allSatisfy { $0.declarationText == $0.name })
        let declarationTexts = displayedDeclarationTexts(of: located, in: interface)
        #expect(declarationTexts[0] == "@property (nonatomic) NSInteger count;")
        #expect(declarationTexts[1] == "- (void)setValue:(id)value forKey:(NSString *)key;")
        #expect(declarationTexts[3] == "NSInteger _count;")
        #expect(declarationTexts[4] == "missing")
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
        let declarationTexts = displayedDeclarationTexts(of: located, in: interface)
        #expect(declarationTexts[4] == "subscript(index: Int) -> Int")
        #expect(declarationTexts[5] == "init(count: Int)")
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

    /// The fixtures below spell what MachOObjCSection's and
    /// MachOSwiftSection's renderers print, span for span. The members are
    /// listed out of printed order on purpose: where a member lands must not
    /// depend on it.
    @Test("Objective-C members that share a name each get their own line, whatever order they are listed in")
    func objectiveCMembersSharingAName() {
        /// ```
        ///  1 @interface Fixture : NSObject {
        ///  2     BOOL colorFromColorPanel;
        ///  3     struct {
        ///  4         unsigned int hidesBottomBarWhenPushed : 1;
        ///  5     } _viewControllerFlags;
        ///  6 }
        ///  7 @property (class) NSInteger shared;
        ///  8 @property NSInteger shared;
        ///  9 @property BOOL colorFromColorPanel; // @synthesize colorFromColorPanel
        /// 10 @property BOOL hidesBottomBarWhenPushed;
        /// 11 + (id)make;
        /// 12 - (id)make;
        /// 13 - (void)make:(id)value;
        /// 14 @end
        /// ```
        let interface: FrozenSemanticString = SemanticString {
            Keyword("@interface")
            Standard(" ")
            TypeDeclaration(kind: .class, "Fixture")
            Standard(" : ")
            TypeName(kind: .class, "NSObject")
            Standard(" {\n    ")
            Keyword("BOOL")
            Standard(" ")
            Variable("colorFromColorPanel")
            Standard(";\n    ")
            Keyword("struct")
            Standard(" {\n        ")
            Keyword("unsigned")
            Standard(" ")
            Keyword("int")
            Standard(" ")
            // `ObjCField` prints a struct's fields, bitfields included, as variables.
            Variable("hidesBottomBarWhenPushed")
            Standard(" : ")
            Numeric(1)
            Standard(";\n    } ")
            Variable("_viewControllerFlags")
            Standard(";\n}\n")
            Keyword("@property")
            Standard(" (")
            Keyword("class")
            Standard(") ")
            TypeName(kind: .other, "NSInteger")
            Standard(" ")
            MemberDeclaration("shared")
            Standard(";\n")
            Keyword("@property")
            Standard(" ")
            TypeName(kind: .other, "NSInteger")
            Standard(" ")
            MemberDeclaration("shared")
            Standard(";\n")
            Keyword("@property")
            Standard(" ")
            Keyword("BOOL")
            Standard(" ")
            MemberDeclaration("colorFromColorPanel")
            Standard("; ")
            Comment("@synthesize colorFromColorPanel")
            Standard("\n")
            Keyword("@property")
            Standard(" ")
            Keyword("BOOL")
            Standard(" ")
            MemberDeclaration("hidesBottomBarWhenPushed")
            Standard(";\n+ (")
            Keyword("id")
            Standard(")")
            FunctionDeclaration("make")
            Standard(";\n- (")
            Keyword("id")
            Standard(")")
            FunctionDeclaration("make")
            Standard(";\n- (")
            Keyword("void")
            Standard(")")
            FunctionDeclaration("make")
            Standard(":(")
            Keyword("id")
            Standard(")")
            Argument("value")
            Standard(";\n")
            Keyword("@end")
        }.frozen()

        let located = RuntimeMemberDeclarationLocator.locate([
            member("make:", .objcMethod),
            member("shared", .objcProperty),
            member("colorFromColorPanel", .objcProperty),
            member("hidesBottomBarWhenPushed", .objcProperty),
            member("shared", .objcProperty, isStatic: true),
            member("colorFromColorPanel", .objcIvar),
            member("_viewControllerFlags", .objcIvar),
            member("make", .objcMethod),
            member("make", .objcMethod, isStatic: true),
        ], in: interface)

        #expect(located.map(\.lineNumber) == [13, 8, 9, 10, 7, 2, 5, 12, 11])
    }

    @Test("initializer and subscript labels are not function names, and static members keep to static lines")
    func swiftLabelsAndStaticMembers() {
        /// ```
        ///  1 struct Angle {
        ///  2     init(degrees: Swift.Double)
        ///  3     init(radians: Swift.Double)
        ///  4     var degrees: Swift.Double {
        ///  5         get
        ///  6     }
        ///  7     subscript(degrees: Swift.Int) -> Swift.Double {
        ///  8         get
        ///  9     }
        /// 10     static var zero: Angle {
        /// 11         get
        /// 12     }
        /// 13     var zero: Angle {
        /// 14         get
        /// 15     }
        /// 16     static func degrees(_: Swift.Double) -> Angle
        /// 17     static func radians(_: Swift.Double) -> Angle
        /// 18 }
        /// ```
        let interface: FrozenSemanticString = SemanticString {
            Keyword("struct")
            Standard(" ")
            TypeDeclaration(kind: .struct, "Angle")
            Standard(" {\n    ")
            Keyword("init")
            Standard("(")
            // An argument label is printed as a function declaration, the
            // way a function's base name is.
            FunctionDeclaration("degrees")
            Standard(": ")
            TypeName(kind: .struct, "Swift.Double")
            Standard(")\n    ")
            Keyword("init")
            Standard("(")
            FunctionDeclaration("radians")
            Standard(": ")
            TypeName(kind: .struct, "Swift.Double")
            Standard(")\n    ")
            Keyword("var")
            Standard(" ")
            Variable("degrees")
            Standard(": ")
            TypeName(kind: .struct, "Swift.Double")
            Standard(" {\n        ")
            Keyword("get")
            Standard("\n    }\n    ")
            Keyword("subscript")
            Standard("(")
            FunctionDeclaration("degrees")
            Standard(": ")
            TypeName(kind: .struct, "Swift.Int")
            Standard(") -> ")
            TypeName(kind: .struct, "Swift.Double")
            Standard(" {\n        ")
            Keyword("get")
            Standard("\n    }\n    ")
            Keyword("static")
            Standard(" ")
            Keyword("var")
            Standard(" ")
            Variable("zero")
            Standard(": ")
            TypeName(kind: .struct, "Angle")
            Standard(" {\n        ")
            Keyword("get")
            Standard("\n    }\n    ")
            Keyword("var")
            Standard(" ")
            Variable("zero")
            Standard(": ")
            TypeName(kind: .struct, "Angle")
            Standard(" {\n        ")
            Keyword("get")
            Standard("\n    }\n    ")
            Keyword("static")
            Standard(" ")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("degrees")
            Standard("(")
            FunctionDeclaration("_")
            Standard(": ")
            TypeName(kind: .struct, "Swift.Double")
            Standard(") -> ")
            TypeName(kind: .struct, "Angle")
            Standard("\n    ")
            Keyword("static")
            Standard(" ")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("radians")
            Standard("(")
            FunctionDeclaration("_")
            Standard(": ")
            TypeName(kind: .struct, "Swift.Double")
            Standard(") -> ")
            TypeName(kind: .struct, "Angle")
            Standard("\n}")
        }.frozen()

        let located = RuntimeMemberDeclarationLocator.locate([
            member("degrees", .swiftFunction, isStatic: true),
            member("radians", .swiftFunction, isStatic: true),
            member("zero", .swiftVariable),
            member("zero", .swiftVariable, isStatic: true),
            member("degrees", .swiftVariable),
            member("subscript", .swiftSubscript),
            // The sections list an initializer as static.
            member("init", .swiftInitializer, isStatic: true),
            member("init", .swiftInitializer, isStatic: true),
        ], in: interface)

        #expect(located.map(\.lineNumber) == [16, 17, 13, 10, 4, 7, 2, 3])
    }

    @Test("a member printed under both verdicts on Objective-C evidence claims one line")
    func memberPrintedUnderBothVerdicts() {
        /// When the verdicts with and without selector-name evidence give a
        /// member different attributes, the corpus prints it under each, the
        /// second right where the first ends (`printUnderObjCVerdicts`): on
        /// the same line for a function, on the first one's closing-brace
        /// line for a variable. The default implementations follow in an
        /// extension.
        /// ```
        ///  1 protocol Describing {
        ///  2     @objc var summary: Swift.String {
        ///  3         get
        ///  4     }var summary: Swift.String {
        ///  5         get
        ///  6     }
        ///  7     @objc func describe() -> Swift.Stringfunc describe() -> Swift.String
        ///  8 }
        ///  9 extension Describing {
        /// 10     var summary: Swift.String {
        /// 11         get
        /// 12     }
        /// 13     func describe() -> Swift.String
        /// 14 }
        /// ```
        let interface: FrozenSemanticString = SemanticString {
            Keyword("protocol")
            Standard(" ")
            TypeDeclaration(kind: .protocol, "Describing")
            Standard(" {\n    ")
            Keyword("@objc")
            Standard(" ")
            Keyword("var")
            Standard(" ")
            Variable("summary")
            Standard(": ")
            TypeName(kind: .struct, "Swift.String")
            Standard(" {\n        ")
            Keyword("get")
            Standard("\n    }")
            Keyword("var")
            Standard(" ")
            Variable("summary")
            Standard(": ")
            TypeName(kind: .struct, "Swift.String")
            Standard(" {\n        ")
            Keyword("get")
            Standard("\n    }\n    ")
            Keyword("@objc")
            Standard(" ")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("describe")
            Standard("() -> ")
            TypeName(kind: .struct, "Swift.String")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("describe")
            Standard("() -> ")
            TypeName(kind: .struct, "Swift.String")
            Standard("\n}\n")
            Keyword("extension")
            Standard(" ")
            TypeName(kind: .protocol, "Describing")
            Standard(" {\n    ")
            Keyword("var")
            Standard(" ")
            Variable("summary")
            Standard(": ")
            TypeName(kind: .struct, "Swift.String")
            Standard(" {\n        ")
            Keyword("get")
            Standard("\n    }\n    ")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("describe")
            Standard("() -> ")
            TypeName(kind: .struct, "Swift.String")
            Standard("\n}")
        }.frozen()

        // The requirements, then the default implementations.
        let located = RuntimeMemberDeclarationLocator.locate([
            member("summary", .swiftVariable),
            member("describe", .swiftFunction),
            member("summary", .swiftVariable),
            member("describe", .swiftFunction),
        ], in: interface)

        #expect(located.map(\.lineNumber) == [2, 7, 10, 13])
    }

    @Test("an operator function is located by its operator, not by an argument label")
    func operatorFunction() {
        /// The printer writes an operator as plain text after `func`, so
        /// the first function declaration span of the line is a label.
        /// ```
        /// 1 struct Mask {
        /// 2     static func == (_: Mask, _: Mask) -> Swift.Bool
        /// 3     static func _(_: Mask) -> Mask
        /// 4 }
        /// ```
        let interface: FrozenSemanticString = SemanticString {
            Keyword("struct")
            Standard(" ")
            TypeDeclaration(kind: .struct, "Mask")
            Standard(" {\n    ")
            Keyword("static")
            Standard(" ")
            Keyword("func")
            Standard(" == (")
            FunctionDeclaration("_")
            Standard(": ")
            TypeName(kind: .struct, "Mask")
            Standard(", ")
            FunctionDeclaration("_")
            Standard(": ")
            TypeName(kind: .struct, "Mask")
            Standard(") -> ")
            TypeName(kind: .struct, "Swift.Bool")
            Standard("\n    ")
            Keyword("static")
            Standard(" ")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("_")
            Standard("(")
            FunctionDeclaration("_")
            Standard(": ")
            TypeName(kind: .struct, "Mask")
            Standard(") -> ")
            TypeName(kind: .struct, "Mask")
            Standard("\n}")
        }.frozen()

        let located = RuntimeMemberDeclarationLocator.locate([
            member("_", .swiftFunction, isStatic: true),
            member("==", .swiftFunction, isStatic: true),
        ], in: interface)

        #expect(located.map(\.lineNumber) == [3, 2])
    }
}
