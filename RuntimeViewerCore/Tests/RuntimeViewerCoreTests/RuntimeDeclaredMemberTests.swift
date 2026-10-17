import Foundation
import Semantic
import Testing
@testable import RuntimeViewerCore

/// The member each line of an interface declares — what the content pane offers the
/// cross-reference commands for: one member per line, of the interface's own language, and none
/// inside a nested type's braces.
@Suite("RuntimeObjectInterface.declaredMembersByLineNumber")
struct RuntimeDeclaredMemberTests {
    private static func interface(_ kind: RuntimeObjectKind, _ text: FrozenSemanticString) -> RuntimeObjectInterface {
        RuntimeObjectInterface(object: RuntimeObject(name: "Foo", displayName: "Foo", kind: kind, imagePath: "/Fixture", children: []), interfaceString: text)
    }

    @Test("Objective-C: each selector, class method, property and ivar on its line, and only those")
    func objectiveC() {
        /// ```
        /// @interface Foo : NSObject {      1
        ///     NSInteger _count;            2
        /// }                                3
        /// @property (nonatomic) NSInteger count;   4
        /// - (void)setValue:(id)value forKey:(NSString *)key;   5
        /// + (instancetype)shared;          6
        /// @end                             7
        /// ```
        let text: FrozenSemanticString = SemanticString {
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
            FunctionDeclaration("setValue")
            Standard(":(id)")
            Variable("value")
            Standard(" ")
            FunctionDeclaration("forKey")
            Standard(":(NSString *)")
            Variable("key")
            Standard(";\n+ (instancetype)")
            FunctionDeclaration("shared")
            Standard(";\n")
            Keyword("@end")
        }.frozen()

        let members = Self.interface(.objc(.type(.class)), text).declaredMembersByLineNumber()

        #expect(members[2] == RuntimeDeclaredMember(name: "_count", kind: .objcIvar, isStatic: false))
        #expect(members[4] == RuntimeDeclaredMember(name: "count", kind: .objcProperty, isStatic: false))
        #expect(members[5] == RuntimeDeclaredMember(name: "setValue:forKey:", kind: .objcMethod, isStatic: false), "the method, not its parameters")
        #expect(members[6] == RuntimeDeclaredMember(name: "shared", kind: .objcMethod, isStatic: true))
        #expect(Set(members.keys) == [2, 4, 5, 6], "no Swift key is read off an Objective-C line")
    }

    @Test("Swift: functions over their argument names, initializers, subscripts, statics and enum cases")
    func swift() {
        /// ```
        /// enum Foo {                       1
        ///     case first                   2
        ///     var count: Int               3
        ///     init(count: Int)             4
        ///     func foo(bar: Int)           5
        ///     static func make() -> Foo    6
        ///     subscript(index: Int) -> Int 7
        /// }                                8
        /// ```
        let text: FrozenSemanticString = SemanticString {
            Keyword("enum")
            Standard(" ")
            TypeName(kind: .enum, "Foo")
            Standard(" {\n    ")
            Keyword("case")
            Standard(" ")
            MemberDeclaration("first")
            Standard("\n    ")
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
            Keyword("static")
            Standard(" ")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("make")
            Standard("() -> Foo\n    ")
            Keyword("subscript")
            Standard("(index: Int) -> Int\n}")
        }.frozen()

        let members = Self.interface(.swift(.type(.enum)), text).declaredMembersByLineNumber()

        #expect(members[2] == RuntimeDeclaredMember(name: "first", kind: .swiftEnumCase, isStatic: false))
        #expect(members[3] == RuntimeDeclaredMember(name: "count", kind: .swiftVariable, isStatic: false))
        #expect(members[4] == RuntimeDeclaredMember(name: "init", kind: .swiftInitializer, isStatic: false))
        #expect(members[5] == RuntimeDeclaredMember(name: "foo", kind: .swiftFunction, isStatic: false))
        #expect(members[6] == RuntimeDeclaredMember(name: "make", kind: .swiftFunction, isStatic: true))
        #expect(members[7] == RuntimeDeclaredMember(name: "subscript", kind: .swiftSubscript, isStatic: false))
        #expect(members[1] == nil && members[8] == nil)
    }

    @Test("a nested type's members, printed inside the object's braces, are not the object's")
    func nestedTypesAreLeftOut() {
        /// ```
        /// struct Outer {                   1
        ///     struct Inner {               2
        ///         func inner()             3
        ///     }                            4
        ///     func outer()                 5
        /// }                                6
        /// ```
        let text: FrozenSemanticString = SemanticString {
            Keyword("struct")
            Standard(" ")
            TypeName(kind: .struct, "Outer")
            Standard(" {\n    ")
            Keyword("struct")
            Standard(" ")
            TypeName(kind: .struct, "Inner")
            Standard(" {\n        ")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("inner")
            Standard("()\n    }\n    ")
            Keyword("func")
            Standard(" ")
            FunctionDeclaration("outer")
            Standard("()\n}")
        }.frozen()

        let members = Self.interface(.swift(.type(.struct)), text).declaredMembersByLineNumber()

        #expect(members[3] == nil)
        #expect(members[5] == RuntimeDeclaredMember(name: "outer", kind: .swiftFunction, isStatic: false))
    }
}
