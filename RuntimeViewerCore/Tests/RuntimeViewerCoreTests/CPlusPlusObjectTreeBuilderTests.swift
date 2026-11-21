import Foundation
import Testing
@testable import RuntimeViewerCore

@Suite("C++ object tree")
struct CPlusPlusObjectTreeBuilderTests {
    private typealias Scope = CPlusPlusObjectTreeBuilder.Scope

    private static let imagePath = "/usr/lib/libExample.dylib"

    private static func scope(_ path: [String], _ kind: Scope.Kind, hasMembers: Bool = false, children: [Scope] = []) -> Scope {
        Scope(path: path, kind: kind, hasMembers: { hasMembers }, children: children)
    }

    private static func objects(globalHasMembers: Bool = false, _ scopes: [Scope], classPaths: [[String]] = []) -> [RuntimeObject] {
        CPlusPlusObjectTreeBuilder(imagePath: imagePath).objects(
            globalScope: scope([], .namespace, hasMembers: globalHasMembers, children: scopes),
            classPaths: classPaths
        )
    }

    /// Every object below `objects`, keyed by name.
    private static func flattened(_ objects: [RuntimeObject]) -> [String: RuntimeObject] {
        var result: [String: RuntimeObject] = [:]
        func visit(_ object: RuntimeObject) {
            result[object.name] = object
            object.children.forEach(visit)
        }
        objects.forEach(visit)
        return result
    }

    @Test("a type scope is a class object, named in full and shown by its last component")
    func typeScopeBecomesClassObject() throws {
        let objects = Self.objects([
            Self.scope(["llvm"], .namespace, children: [
                Self.scope(["llvm", "Value"], .type, hasMembers: true),
            ]),
        ])
        let value = try #require(Self.flattened(objects)["llvm::Value"])
        #expect(value.kind == .cPlusPlus(.class))
        #expect(value.displayName == "Value")
        #expect(value.imagePath == Self.imagePath)
        #expect(objects.map(\.name) == ["llvm"])
        #expect(objects.first?.kind == .cPlusPlus(.namespace))
    }

    @Test("a class only run-time type information shows is placed under its scope path")
    func typeInfoOnlyClassIsPlacedUnderItsScopePath() throws {
        let objects = Self.objects([
            Self.scope(["TST"], .namespace, hasMembers: true),
        ], classPaths: [["TST", "TSTUidOrderNode"]])
        let node = try #require(Self.flattened(objects)["TST::TSTUidOrderNode"])
        #expect(node.kind == .cPlusPlus(.class))
        #expect(objects.first?.children.map(\.name) == ["TST::TSTUidOrderNode"])
    }

    @Test("the missing scopes above such a class are made up, as classes inside a class")
    func missingParentOfTypeInfoOnlyClassBecomesNamespace() throws {
        let objects = Self.objects([], classPaths: [["Outer", "Middle", "Inner"]])
        let byName = Self.flattened(objects)
        #expect(byName["Outer"]?.kind == .cPlusPlus(.namespace))
        #expect(byName["Outer::Middle"]?.kind == .cPlusPlus(.namespace))
        #expect(byName["Outer::Middle::Inner"]?.kind == .cPlusPlus(.class))

        let nested = Self.flattened(Self.objects([], classPaths: [["Owner"], ["Owner", "Middle", "Inner"]]))
        #expect(nested["Owner"]?.kind == .cPlusPlus(.class))
        #expect(nested["Owner::Middle"]?.kind == .cPlusPlus(.class))
    }

    @Test("run-time type information turns an undetermined or namespace scope into a class")
    func typeInfoTurnsUndeterminedScopeIntoClass() {
        let byName = Self.flattened(Self.objects([
            Self.scope(["Undetermined"], .undetermined, hasMembers: true),
            Self.scope(["Namespace"], .namespace, hasMembers: true),
        ], classPaths: [["Undetermined"], ["Namespace"]]))
        #expect(byName["Undetermined"]?.kind == .cPlusPlus(.class))
        #expect(byName["Namespace"]?.kind == .cPlusPlus(.class))
    }

    @Test("an undetermined scope with symbols is a namespace")
    func undeterminedScopeIsNamespace() {
        let byName = Self.flattened(Self.objects([Self.scope(["helpers"], .undetermined, hasMembers: true)]))
        #expect(byName["helpers"]?.kind == .cPlusPlus(.namespace))
    }

    @Test("function scopes are dropped with everything inside them")
    func functionScopesAreDropped() {
        let byName = Self.flattened(Self.objects([
            Self.scope(["app"], .namespace, children: [
                Self.scope(["app", "run()"], .function, hasMembers: true, children: [
                    Self.scope(["app", "run()", "Local"], .type, hasMembers: true),
                ]),
                Self.scope(["app", "Kept"], .type),
            ]),
        ], classPaths: [["app", "run()", "Local"], ["main()", "Lambda"]]))
        #expect(byName.keys.sorted() == ["app", "app::Kept"])
    }

    @Test("a namespace with no symbol and nothing below it is left out; an empty type is kept")
    func emptyNamespacesAreDropped() {
        let byName = Self.flattened(Self.objects([
            Self.scope(["empty"], .namespace, children: [
                Self.scope(["empty", "alsoEmpty"], .namespace),
            ]),
            Self.scope(["holder"], .namespace, children: [
                Self.scope(["holder", "Marker"], .type),
            ]),
        ]))
        #expect(byName.keys.sorted() == ["holder", "holder::Marker"])
    }

    @Test("a namespace that keeps something below it is not asked for its members")
    func namespaceWithChildrenIsNotAskedForMembers() {
        let asked = AskedFlag()
        let objects = CPlusPlusObjectTreeBuilder(imagePath: Self.imagePath).objects(
            globalScope: Self.scope([], .namespace, children: [
                Scope(path: ["std"], kind: .namespace, hasMembers: { asked.set(); return false }, children: [
                    Self.scope(["std", "exception"], .type),
                ]),
            ]),
            classPaths: []
        )
        #expect(objects.map(\.name) == ["std"])
        #expect(!asked.value)
    }

    @Test("symbols at global scope get the Global Namespace object")
    func globalMembersGetGlobalNamespaceObject() throws {
        let objects = Self.objects(globalHasMembers: true, [Self.scope(["Widget"], .type)])
        let global = try #require(objects.first { $0.name == CPlusPlusObjectTreeBuilder.globalNamespaceName })
        #expect(global.displayName == "Global Namespace")
        #expect(global.kind == .cPlusPlus(.namespace))
        #expect(Self.objects([Self.scope(["Widget"], .type)]).allSatisfy { $0.name != "::" })
    }

    @Test("a component is a function when a parenthesis stands outside its template arguments")
    func functionComponentsAreRecognized() {
        #expect(CPlusPlusObjectTreeBuilder.isFunctionComponent("run()"))
        #expect(CPlusPlusObjectTreeBuilder.isFunctionComponent("compare(int, int) const"))
        #expect(!CPlusPlusObjectTreeBuilder.isFunctionComponent("(anonymous namespace)"))
        #expect(!CPlusPlusObjectTreeBuilder.isFunctionComponent("function<void (int)>"))
        #expect(!CPlusPlusObjectTreeBuilder.isFunctionComponent("vector<int, std::__1::allocator<int>>"))
    }

    @Test("children are sorted, classes before namespaces")
    func childrenAreSorted() {
        let objects = Self.objects([
            Self.scope(["ns"], .namespace, children: [
                Self.scope(["ns", "zeta"], .namespace, hasMembers: true),
                Self.scope(["ns", "Beta"], .type),
                Self.scope(["ns", "Alpha"], .type),
            ]),
        ])
        #expect(objects.first?.children.map(\.displayName) == ["Alpha", "Beta", "zeta"])
    }
}

/// Whether a closure was called, readable after the call.
private final class AskedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool { lock.withLock { isSet } }

    func set() { lock.withLock { isSet = true } }
}
